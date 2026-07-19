// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {IStockToken} from "./interfaces/IStockToken.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";

/// @title RedemptionVault — the NAV floor, from scratch. No launchpad, no Guardian.
/// @notice Holds the AI-infrastructure Stock Token basket bought by the BuybackEngine
///         (engine sink = this vault). Holders burn TTP to redeem their pro-rata slice
///         at NAV, time-weighted over a 30d maturity ramp. Supply only shrinks (burns
///         to 0xdead; circulating = totalSupply - dead), backing only grows.
///         vs competitors: INDEX/RIF distribute stocks away (no backing); VAULTS holds
///         nothing ("no deposits or redemptions"). TTP holds the assets. Redeem anytime.
/// @dev    All creator levers DISCLOSED: redemptionFeeBps -> treasury; a
///         forfeitureCreatorShareBps slice of the early-redemption haircut -> creator
///         wallet; remainder of the haircut accretes to remaining holders.
///         INVARIANT (test-enforced): NAV-per-circulating-token never decreases from
///         redemptions — neutral at full maturity, strictly accretive early.
contract RedemptionVault {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    enum Status { Active, Halted, Delisted }

    struct Constituent { address token; address feed; uint16 weightBps; Status status; }

    address public admin;                    // creator ops; renounce/multisig later
    IERC20 public immutable ttp;
    address public treasury;
    address public forfeitureCreatorWallet;
    uint16 public redemptionFeeBps;          // 100 = 1%
    uint16 public earlyRedemptionFloorBps;   // 9000 -> 10000 over maturityPeriod
    uint16 public forfeitureCreatorShareBps; // 5000 = half the haircut
    uint32 public maturityPeriod;            // 30 days
    uint256 public stalenessWindow;          // Chainlink max age
    Constituent[] public basket;
    uint256[] public scales; // 10^(18 - token decimals) per constituent

    mapping(address => uint64) public acquiredAt;

    event MaturityStarted(address indexed who, uint64 t0);
    event Redeemed(address indexed who, uint256 ttpBurned, uint256 weightBps, uint256 creatorForfeitTokens);
    event ConstituentStatus(uint256 indexed idx, Status status);
    event ConstituentAdded(address token, address feed, uint16 weightBps);

    error NotAdmin();
    error BadConfig(string reason);
    error StalePrice(address feed);
    error NothingToRedeem();

    modifier onlyAdmin() { if (msg.sender != admin) revert NotAdmin(); _; }

    constructor(
        address _ttp,
        address _treasury,
        address _forfeitureCreatorWallet,
        uint16 _redemptionFeeBps,
        uint16 _earlyRedemptionFloorBps,
        uint16 _forfeitureCreatorShareBps,
        uint32 _maturityPeriod,
        uint256 _stalenessWindow,
        Constituent[] memory cs
    ) {
        if (_ttp == address(0) || _treasury == address(0)) revert BadConfig("zero addr");
        uint256 n = cs.length;
        if (n == 0 || n > 20) revert BadConfig("len");
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            if (cs[i].token == address(0) || cs[i].feed == address(0)) revert BadConfig("zero constituent");
            for (uint256 j; j < i; ++j) if (cs[j].token == cs[i].token) revert BadConfig("dup");
            sum += cs[i].weightBps;
            basket.push(cs[i]);
            scales.push(10 ** (18 - _dec(cs[i].token))); // normalize balances to 18dp (USDG is 6dp on mainnet)
        }
        if (sum != BPS) revert BadConfig("weights");
        admin = msg.sender;
        ttp = IERC20(_ttp);
        treasury = _treasury;
        forfeitureCreatorWallet = _forfeitureCreatorWallet;
        redemptionFeeBps = _redemptionFeeBps;
        earlyRedemptionFloorBps = _earlyRedemptionFloorBps == 0 ? 9000 : _earlyRedemptionFloorBps;
        forfeitureCreatorShareBps = _forfeitureCreatorShareBps;
        maturityPeriod = _maturityPeriod == 0 ? 30 days : _maturityPeriod;
        stalenessWindow = _stalenessWindow == 0 ? 3600 : _stalenessWindow;
    }

    // engine sink: stock tokens arrive via plain ERC20 transfer; ETH not expected but safe
    receive() external payable {}

    // ---- supply & NAV ----

    /// circulating supply: total minus burned. Redeems burn to DEAD, ratcheting NAV/token.
    function circulatingSupply() public view returns (uint256) {
        return ttp.totalSupply() - ttp.balanceOf(DEAD);
    }

    function _price(address feed) internal view returns (uint256, uint8) {
        (, int256 p,, uint256 updatedAt,) = IAggregatorV3(feed).latestRoundData();
        if (p <= 0 || updatedAt == 0 || block.timestamp - updatedAt > stalenessWindow) revert StalePrice(feed);
        return (uint256(p), IAggregatorV3(feed).decimals());
    }

    /// token balances normalized to 18dp via scales (mainnet USDG is 6dp); result is 18dp USD.
    function nav() public view returns (uint256 total) {
        uint256 n = basket.length;
        for (uint256 i; i < n; ++i) {
            Constituent storage k = basket[i];
            (uint256 p, uint8 d) = _price(k.feed);
            total += (IStockToken(k.token).balanceOf(address(this)) * scales[i] * p) / (10 ** d);
        }
    }

    /// token decimals with an 18 fallback (defensive; all real tokens implement decimals())
    function _dec(address token) internal view returns (uint8) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("decimals()"));
        if (ok && ret.length >= 32) return abi.decode(ret, (uint8));
        return 18;
    }

    function navPerToken() public view returns (uint256) {
        uint256 supply = circulatingSupply();
        if (supply == 0) return 0;
        return (nav() * WAD) / supply;
    }

    // ---- maturity ramp ----

    /// Opt in to start your 30d ramp from the floor (90%) to full NAV. Idempotent.
    function startMaturity() external {
        if (acquiredAt[msg.sender] == 0) {
            acquiredAt[msg.sender] = uint64(block.timestamp);
            emit MaturityStarted(msg.sender, uint64(block.timestamp));
        }
    }

    function timeWeightBps(address who) public view returns (uint256) {
        uint64 t0 = acquiredAt[who];
        if (t0 == 0) return earlyRedemptionFloorBps;
        uint256 elapsed = block.timestamp - t0;
        if (elapsed >= maturityPeriod) return BPS;
        uint256 floor = earlyRedemptionFloorBps;
        return floor + ((BPS - floor) * elapsed) / maturityPeriod;
    }

    // ---- redeem: burn TTP, take your slice ----

    /// @notice Burn `amount` TTP (to 0xdead) and receive your pro-rata slice of every
    ///         active constituent, scaled by your maturity weight. Haircut splits:
    ///         `forfeitureCreatorShareBps` -> creator wallet, rest stays (accretes to
    ///         holders). Fee -> treasury. Reentrancy-safe: burn precedes transfers and
    ///         Stock Tokens are known non-callback ERC20s.
    function redeem(uint256 amount) external {
        if (amount == 0) revert NothingToRedeem();
        uint256 supply = circulatingSupply();
        uint256 wBps = timeWeightBps(msg.sender);

        // pull + burn first (supply snapshot taken before burn)
        require(ttp.transferFrom(msg.sender, address(this), amount), "pull");
        require(ttp.transfer(DEAD, amount), "burn");

        uint256 creatorTotal;
        uint256 n = basket.length;
        for (uint256 i; i < n; ++i) {
            Constituent storage k = basket[i];
            if (k.status == Status.Delisted) continue;
            uint256 held = IStockToken(k.token).balanceOf(address(this));
            if (held == 0) continue;
            uint256 proRata = (held * amount) / supply;
            uint256 toHolder = (proRata * wBps) / BPS;
            uint256 forfeited = proRata - toHolder;
            uint256 toCreator = (forfeited * forfeitureCreatorShareBps) / BPS;
            uint256 fee = (toHolder * redemptionFeeBps) / BPS;
            uint256 net = toHolder - fee;
            if (net > 0) require(IStockToken(k.token).transfer(msg.sender, net), "x holder");
            if (fee > 0) require(IStockToken(k.token).transfer(treasury, fee), "x fee");
            if (toCreator > 0 && forfeitureCreatorWallet != address(0)) {
                require(IStockToken(k.token).transfer(forfeitureCreatorWallet, toCreator), "x creator");
            }
            creatorTotal += toCreator;
        }
        emit Redeemed(msg.sender, amount, wBps, creatorTotal);
    }

    // ---- views for site/dashboard ----

    function basketComposition() external view returns (Constituent[] memory) { return basket; }

    function pendingRedemptionValue(address who) external view returns (uint256) {
        uint256 supply = circulatingSupply();
        if (supply == 0) return 0;
        return (navPerToken() * ttp.balanceOf(who) * timeWeightBps(who)) / (WAD * BPS);
    }

    // ---- lifecycle (admin; move to multisig at launch, renounce path documented) ----

    function setConstituentStatus(uint256 idx, Status s) external onlyAdmin {
        basket[idx].status = s;
        emit ConstituentStatus(idx, s);
    }

    /// add a reserved constituent (e.g. TSM/ASML once liquid). Weights advisory for the
    /// engine's buys; redemption is strictly pro-rata of holdings, so adding never dilutes.
    function addConstituent(address token, address feed, uint16 weightBps_) external onlyAdmin {
        if (token == address(0) || feed == address(0)) revert BadConfig("zero");
        if (basket.length >= 20) revert BadConfig("len");
        for (uint256 j; j < basket.length; ++j) if (basket[j].token == token) revert BadConfig("dup");
        basket.push(Constituent(token, feed, weightBps_, Status.Active));
        scales.push(10 ** (18 - _dec(token)));
        emit ConstituentAdded(token, feed, weightBps_);
    }

    function transferAdmin(address to) external onlyAdmin {
        if (to == address(0)) revert BadConfig("zero");
        admin = to;
    }
}
