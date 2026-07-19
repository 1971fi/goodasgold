// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";

/// @title Good as Gold (GAG) — USDG-backed token with a claimable USDG dividend accumulator.
/// @notice Fixed supply, 1B. Two holder rails, both in cash (USDG):
///   1. DISTRIBUTION (push-accrual, pull-claim): fees route USDG into `distributeDividends`,
///      which accrues pro-rata to every eligible holder. Holders `claim()` on demand — no
///      dust-spray, no per-wallet gas, scales to any holder count. (Fixes RIF's flaw.)
///   2. FLOOR (separate RedemptionVault): burn GAG to redeem USDG reserve at NAV.
/// @dev Dividend math = the magnified-per-share accumulator pattern, keyed on an explicit
///      "share" per account (= balance, or 0 if excluded). Excluded: the DEX pool, the
///      reserve vault, treasury, dead, this contract. distributeDividends divides by
///      totalShares (eligible supply only) so no USDG is stranded on excluded balances.
///      INVARIANT (test-enforced): Σ withdrawable + Σ withdrawn == Σ distributed (no USDG
///      created or lost); every claim pays exactly accrued.
contract GoodAsGold {
    // --- ERC20 --- ticker $1971 (the year dollar-gold convertibility ended); name is the tagline
    string public constant name = "Good as Gold";
    string public constant symbol = "1971";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // --- dividends (USDG) ---
    uint256 internal constant MAGNITUDE = 2 ** 128;
    IERC20 public immutable usdg;
    uint256 public magnifiedDividendPerShare;
    uint256 public totalDividendsDistributed;
    uint256 public totalShares;
    mapping(address => uint256) public shares;             // eligible balance per account
    mapping(address => int256) internal magnifiedCorrections;
    mapping(address => uint256) public withdrawnDividends;
    mapping(address => bool) public excludedFromDividends;

    address public admin;
    address public distributor;                            // the only address allowed to push USDG

    event DividendsDistributed(address indexed from, uint256 amount);
    event DividendClaimed(address indexed to, uint256 amount);
    event ExcludedFromDividends(address indexed account);

    error NotAdmin();
    error NotDistributor();
    error NoShares();

    modifier onlyAdmin() { if (msg.sender != admin) revert NotAdmin(); _; }

    constructor(address _usdg, uint256 _supply) {
        usdg = IERC20(_usdg);
        admin = msg.sender;
        _mint(msg.sender, _supply == 0 ? 1_000_000_000e18 : _supply);
    }

    // --- ERC20 core ---
    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - value;
        _transfer(from, to, value);
        return true;
    }

    /// redemption path: the vault pulls GAG and burns it. Burning updates shares so burned
    /// tokens stop accruing and the eligible supply shrinks (floor ratchets in the vault).
    function burnFrom(address from, uint256 value) external {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - value;
        balanceOf[from] -= value;
        totalSupply -= value;
        emit Transfer(from, address(0), value);
        _syncShare(from);
    }

    function _transfer(address from, address to, uint256 value) internal {
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
        _syncShare(from);
        _syncShare(to);
    }

    function _mint(address to, uint256 value) internal {
        totalSupply += value;
        balanceOf[to] += value;
        emit Transfer(address(0), to, value);
        _syncShare(to);
    }

    // --- share bookkeeping (keeps accumulative dividends constant across balance changes) ---
    function _syncShare(address account) internal {
        uint256 newShare = excludedFromDividends[account] ? 0 : balanceOf[account];
        uint256 old = shares[account];
        if (newShare == old) return;
        if (newShare > old) {
            uint256 d = newShare - old;
            magnifiedCorrections[account] -= int256(magnifiedDividendPerShare * d);
            totalShares += d;
        } else {
            uint256 d = old - newShare;
            magnifiedCorrections[account] += int256(magnifiedDividendPerShare * d);
            totalShares -= d;
        }
        shares[account] = newShare;
    }

    // --- distribution ---
    function setDistributor(address d) external onlyAdmin { distributor = d; }

    function excludeFromDividends(address account) external onlyAdmin {
        excludedFromDividends[account] = true;
        _syncShare(account);
        emit ExcludedFromDividends(account);
    }

    /// Push USDG in; it accrues pro-rata to eligible holders. Distributor-gated so only the
    /// fee engine funds it (holders never need it approved). USDG must be transferred here.
    function distributeDividends(uint256 amount) external {
        if (msg.sender != distributor && msg.sender != admin) revert NotDistributor();
        if (totalShares == 0) revert NoShares();
        require(usdg.transferFrom(msg.sender, address(this), amount), "pull usdg");
        magnifiedDividendPerShare += (amount * MAGNITUDE) / totalShares;
        totalDividendsDistributed += amount;
        emit DividendsDistributed(msg.sender, amount);
    }

    function accumulativeDividendOf(address account) public view returns (uint256) {
        int256 acc = int256(magnifiedDividendPerShare * shares[account]) + magnifiedCorrections[account];
        return uint256(acc) / MAGNITUDE;
    }

    function withdrawableDividendOf(address account) public view returns (uint256) {
        return accumulativeDividendOf(account) - withdrawnDividends[account];
    }

    /// Holder pulls their accrued USDG. Anyone can trigger for themselves.
    function claim() external returns (uint256) {
        uint256 amount = withdrawableDividendOf(msg.sender);
        if (amount == 0) return 0;
        withdrawnDividends[msg.sender] += amount;
        require(usdg.transfer(msg.sender, amount), "pay usdg");
        emit DividendClaimed(msg.sender, amount);
        return amount;
    }

    function transferAdmin(address to) external onlyAdmin {
        if (to == address(0)) revert NotAdmin();
        admin = to;
    }
}
