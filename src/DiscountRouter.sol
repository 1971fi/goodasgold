// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";

interface INavSource { function navPerToken() external view returns (uint256); }
interface IToken1971 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function totalSupply() external view returns (uint256);
}
/// Concrete impl swaps USDG -> 1971 on the DEX and delivers `to`. The v4 swap wiring is the
/// integration point; the router only trusts the amount actually received.
interface ISwapper { function swapUsdgForToken(uint256 usdgIn, uint256 minOut, address to) external returns (uint256 out); }

/// @title DiscountRouter — buy 1971 below NAV and burn it, to make the floor a HARD floor.
/// @notice Funded by a discount BUFFER held in THIS contract (a slice of fees), kept OUTSIDE
///         the reserve/NAV. Because the spent USDG is not counted in NAV, burning the bought
///         tokens shrinks supply while NAV is unchanged, so navPerToken can only RISE. There
///         is no path that spends the reserve, so no drain risk. The price guard below only
///         prevents overpaying (efficiency), never protects against loss.
/// @dev    ACCRETION PROOF (buffer outside NAV): navPerToken = nav / supply. Burn B tokens ->
///         nav constant, supply -> supply-B, so navPerToken strictly increases for B>0.
///         Manipulation is harmless: pushing price up just fails the minOut guard (no action);
///         pushing price down lets the protocol burn more per dollar (better for holders).
contract DiscountRouter {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IERC20 public immutable usdg;
    uint256 public immutable usdgScale;     // 10^(18 - usdg decimals); mainnet USDG is 6dp
    IToken1971 public immutable token;      // 1971 / Good as Gold
    INavSource public immutable vault;      // navPerToken source
    ISwapper public swapper;
    address public admin;
    uint16 public discountBps;              // require buy price <= navPerToken * (1 - this)
    uint256 public maxSpendPerCall;
    uint256 public cooldown;
    uint256 public lastRun;

    event BoughtAndBurned(uint256 usdgSpent, uint256 burned, uint256 navPerTokenAfter);
    event ParamsSet(uint16 discountBps, uint256 maxSpendPerCall, uint256 cooldown);

    error NotAdmin();
    error Cooldown();
    error OverCap();
    error NoBuffer();
    error NotDiscounted();

    modifier onlyAdmin() { if (msg.sender != admin) revert NotAdmin(); _; }

    constructor(address _usdg, address _token, address _vault, address _swapper, uint16 _discountBps, uint256 _maxSpend, uint256 _cooldown) {
        require(_usdg != address(0) && _token != address(0) && _vault != address(0), "zero");
        require(_discountBps <= BPS, "bps");
        usdg = IERC20(_usdg); token = IToken1971(_token); vault = INavSource(_vault); swapper = ISwapper(_swapper);
        admin = msg.sender; discountBps = _discountBps; maxSpendPerCall = _maxSpend; cooldown = _cooldown;
        (bool ok, bytes memory ret) = _usdg.staticcall(abi.encodeWithSignature("decimals()"));
        usdgScale = 10 ** (18 - ((ok && ret.length >= 32) ? abi.decode(ret, (uint8)) : 18));
    }

    /// Permissionless keeper action. Spends up to `usdgIn` of the buffer to buy 1971 at or below
    /// the discounted NAV, then burns every token bought. Reverts (no-op) if the market cannot
    /// fill at the discount, so it never overpays and never touches the reserve.
    function discountBuyBurn(uint256 usdgIn, uint256 keeperMinOut) external returns (uint256 burned) {
        if (lastRun != 0 && block.timestamp < lastRun + cooldown) revert Cooldown(); // first call always allowed
        if (usdgIn > maxSpendPerCall) revert OverCap();
        uint256 buffer = usdg.balanceOf(address(this));
        if (usdgIn == 0 || usdgIn > buffer) revert NoBuffer();

        uint256 npt = vault.navPerToken();                 // USD per token, WAD (18dp)
        uint256 maxPrice = (npt * (BPS - discountBps)) / BPS;
        // tokens we must receive so that price <= maxPrice; usdgIn normalized to 18dp first
        uint256 requiredOut = maxPrice == 0 ? keeperMinOut : (usdgIn * usdgScale * WAD) / maxPrice;
        uint256 need = requiredOut > keeperMinOut ? requiredOut : keeperMinOut;

        lastRun = block.timestamp;                          // effects before external call
        require(usdg.approve(address(swapper), usdgIn), "approve");
        burned = swapper.swapUsdgForToken(usdgIn, need, address(this));
        if (burned < need) revert NotDiscounted();
        require(token.transfer(DEAD, burned), "burn");      // supply shrinks -> floor rises
        emit BoughtAndBurned(usdgIn, burned, vault.navPerToken());
    }

    function bufferUsdg() external view returns (uint256) { return usdg.balanceOf(address(this)); }

    // --- admin (move to multisig / renounce at launch) ---
    function setSwapper(address s) external onlyAdmin { swapper = ISwapper(s); }
    function setParams(uint16 _discountBps, uint256 _maxSpend, uint256 _cooldown) external onlyAdmin {
        require(_discountBps <= BPS, "bps");
        discountBps = _discountBps; maxSpendPerCall = _maxSpend; cooldown = _cooldown;
        emit ParamsSet(_discountBps, _maxSpend, _cooldown);
    }
    function transferAdmin(address to) external onlyAdmin { require(to != address(0), "zero"); admin = to; }
    /// rescue only USDG buffer (never touches 1971 or reserve); for migrating the buffer
    function rescueUsdg(address to, uint256 amt) external onlyAdmin { require(usdg.transfer(to, amt), "x"); }
}
