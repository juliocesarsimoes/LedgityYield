// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

// Contracts
import "./abstracts/base/ERC20BaseUpgradeable.sol";
import {ERC20WrapperUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20WrapperUpgradeable.sol";
import {InvestUpgradeable} from "./abstracts/InvestUpgradeable.sol";
import {LDYStaking} from "./LDYStaking.sol";

// Libraries & interfaces
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {SUD} from "./libs/SUD.sol";

import {IERC20MetadataUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import {ITransfersListener} from "./interfaces/ITransfersListener.sol";

/**
 * @title LToken
 * @author Lila Rest (lila@ledgity.com)
 * @notice This contract powers every L-Token available on the Ledgity DeFi app
 * A L-Token is:
 * - a wrapper around a stablecoin (e.g., USDC, EUROC)
 * - a yield bearing token (i.e., it generates rewards as soon as a wallet holds it)
 * - backed by RWA (i.e., it is fully collateralized by real world assets)
 * Rewards are distributed in the L-Token itself, and rewarded L-Tokens are auto-compounded
 * and so automatically re-invested through time
 * @dev For further details, see "LToken" section of whitepaper.
 * @custom:security-contact security@ledgity.com
 * @custom:oz-upgrades-unsafe-allow external-library-linking
 */
contract LToken is ERC20BaseUpgradeable, InvestUpgradeable, ERC20WrapperUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    /// @dev Used to represent the action that triggered an ActivityEvent.
    enum Action {
        Deposit,
        Withdraw
    }

    /// @dev Used to represent the status of the action that triggered an ActivityEvent.
    enum Status {
        Queued,
        Cancelled,
        Success
    }

    /**
     * @dev Represents a queued withdrawal request.
     * @param account The account that emitted the request
     * @param amount The amount of underlying requested
     */
    struct WithdrawalRequest {
        address account; // 20 bytes
        uint96 amount; // 12 bytes
    }

    /// @dev Hard ceil cap on the retention rate
    uint32 private constant MAX_RETENTION_RATE_UD7x3 = 10 * 10 ** 3; // 10%

    /// @dev Used in activity events to represent the absence of an ID.
    int256 private constant NO_ID = -1;

    /// @dev Holds address of the LDYStaking contract
    LDYStaking public ldyStaking;

    /// @dev Holds address of withdrawer wallet (managed by withdrawal server)
    address payable public withdrawer;

    /// @dev Holds address of fund wallet (managed by financial team)
    address public fund;

    /// @dev Holds the withdrawal fee rate in UD7x3 format (3 digits fixed point, e.g., 0.350% = 350)
    uint32 public feesRateUD7x3;

    /// @dev Holds the retention rate in UD7x3 format. See "Retention rate" section of whitepaper.
    uint32 public retentionRateUD7x3;

    /// @dev Holds withdrawal that are unclaimed yet by contract owner.
    uint256 public unclaimedFees;

    /// @dev Holds the amount of L-Tokens currently in the withdrawal queue.
    uint256 public totalQueued;

    /**
     * @dev Holds the total amount of underlying tokens flagged as "usable" to the
     * contract. Are considered "usable" all the underlying tokens deposit through
     * deposit() or fund() functions
     * */
    uint256 public usableUnderlyings;

    /// @dev Holds an ordered list of withdrawal requests.
    WithdrawalRequest[] public withdrawalQueue;

    /// @dev Holds all currently frozen withdrawal requests
    WithdrawalRequest[] public frozenRequests;

    /// @dev Holds the index of the next withdrawal request to process in the queue.
    uint256 public withdrawalQueueCursor;

    /// @dev Holds a list of external contracts to trigger onLTokenTransfer() function on transfer.
    ITransfersListener[] public transfersListeners;

    /**
     * @dev Emitted to inform listeners about a change in the TVL of the contract (a.k.a totalSupply)
     * @param newTVL The new TVL of the contract
     */
    event TVLUpdateEvent(uint256 newTVL);

    /**
     * @dev Emitted to inform listerners about an activity related to deposit and withdrawals.
     * @param id (optional) Used to dedup withdrawal requests events while indexing. Else -1 (NO_ID).
     * @param account The account concerned by the activity.
     * @param action The action that triggered the event.
     * @param amount The amount of underlying tokens involved in the activity.
     * @param newStatus The new status of the activity.
     */
    event ActivityEvent(
        int256 indexed id,
        address indexed account,
        Action indexed action,
        uint256 amount,
        uint256 amountAfterFees,
        Status newStatus
    );

    /**
     * @dev Emitted to inform listeners that some rewards have been minted.
     * @param account The account that received the rewards.
     * @param balanceBefore The balance of the account before the minting.
     * @param rewards The amount of rewards minted.
     */
    event MintedRewardsEvent(address indexed account, uint256 balanceBefore, uint256 rewards);

    /**
     * @dev Restricts wrapped function to the withdrawal server's wallet (a.k.a withdrawer).
     */
    modifier onlyWithdrawer() {
        require(_msgSender() == withdrawer, "L39");
        _;
    }

    /**
     * @dev Restricts wrapped function to the fund wallet (detained by financial team).
     */
    modifier onlyFund() {
        require(_msgSender() == fund, "L40");
        _;
    }

    /**
     * @dev Replaces the constructor() function in context of an upgradeable contract.
     * See: https://docs.openzeppelin.com/contracts/4.x/upgradeable
     * @param globalOwner_ The address of the GlobalOwner contract
     * @param globalPause_ The address of the GlobalPauser contract
     * @param globalBlacklist_ The address of the GlobalBlacklist contract
     * @param underlyingToken The address of the underlying stablecoin
     */
    function initialize(
        address globalOwner_,
        address globalPause_,
        address globalBlacklist_,
        address ldyStaking_,
        address underlyingToken
    ) public initializer {
        // Retrieve underlying token metadata
        IERC20MetadataUpgradeable underlyingMetadata = IERC20MetadataUpgradeable(underlyingToken);

        // Initialize ancestors contracts
        __ERC20Base_init(
            globalOwner_,
            globalPause_,
            globalBlacklist_,
            string(abi.encodePacked("Ledgity ", underlyingMetadata.name())),
            string(abi.encodePacked("L", underlyingMetadata.symbol()))
        );
        __ERC20Wrapper_init(IERC20Upgradeable(underlyingToken));
        __Invest_init_unchained(address(this));

        // Set LDYStaking contract
        setLDYStaking(ldyStaking_);

        // Set initial withdrawal fees rate to 0.3%
        setFeesRate(300);

        // Set initial retention rate to 5%
        setRetentionRate(5000);
    }

    /**
     * @dev Required override of paused() which is implemented by both
     * GlobalPausableUpgradeable and ERC20BaseUpgradeable parent contracts.
     * Both version are the same as ERC20BaseUpgradeable.paused() mirrors
     * GlobalPausableUpgradeable.paused()
     * @inheritdoc GlobalPausableUpgradeable
     */
    function paused()
        public
        view
        virtual
        override(GlobalPausableUpgradeable, ERC20BaseUpgradeable)
        returns (bool)
    {
        return GlobalPausableUpgradeable.paused();
    }

    /**
     * @dev Setter for the withdrawal fee rate.
     * @param feesRateUD7x3_ The new withdrawal fee rate in UD7x3 format
     */
    function setFeesRate(uint32 feesRateUD7x3_) public onlyOwner {
        feesRateUD7x3 = feesRateUD7x3_;
    }

    /**
     * @dev Setter for the underlying token retention rate.
     * Security note: As a security measure, the retention rate is ceiled to 10%, which
     * ensures that this contract will never holds more than 10% of the deposit assets
     * at the same time.
     * @param retentionRateUD7x3_ The new retention rate in UD7x3 format
     */
    function setRetentionRate(uint32 retentionRateUD7x3_) public onlyOwner {
        require(retentionRateUD7x3_ <= MAX_RETENTION_RATE_UD7x3, "L41");
        retentionRateUD7x3 = retentionRateUD7x3_;
    }

    /**
     * @dev Setter for the LDYStaking contract address.
     * @param ldyStakingAddress The address of the new LDYStaking contract
     */
    function setLDYStaking(address ldyStakingAddress) public onlyOwner {
        ldyStaking = LDYStaking(ldyStakingAddress);
    }

    /**
     * @dev Setter for the withdrawer wallet address.
     * @param withdrawer_ The address of the new withdrawer wallet
     */
    function setWithdrawer(address payable withdrawer_) public onlyOwner {
        // Ensure new address is not the zero address
        // Else pre-processing fees would be lost
        require(withdrawer_ != address(0), "L63");

        // Else set new withdrawer address
        withdrawer = withdrawer_;
    }

    /**
     * @dev Setter for the fund wallet address.
     * @param fund_ The address of the new fund wallet
     */
    function setFund(address payable fund_) public onlyOwner {
        // Ensure new address is not the zero address
        // Else underlying tokens would be lost
        require(fund_ != address(0), "L64");

        // Else set new fund address
        fund = fund_;
    }

    /**
     * @notice Allow given contract to listen to L-Token transfers. To do so the
     * onLTokenTransfer() function of the given contract will be called each time
     * a transfer occurs.
     * @param listenerContract The address of the contract to allow listening to transfers
     * @dev IMPORTANT: This method is not intended to be used with contract not owned by
     * the Ledgity team.
     */
    function listenToTransfers(address listenerContract) public onlyOwner {
        transfersListeners.push(ITransfersListener(listenerContract));
    }

    /**
     * @dev Allow given contract to stop listening for L-Token transfers.
     * @param listenerContract The address of the contract to allow listening to transfers
     */
    function unlistenToTransfers(address listenerContract) public onlyOwner {
        // Find index of listener contract in transferListeners array
        int256 index = -1;
        uint256 transfersListenersLength = transfersListeners.length;
        for (uint256 i = 0; i < transfersListenersLength; i++) {
            if (address(transfersListeners[i]) == listenerContract) {
                index = int256(i);
                break;
            }
        }

        // Revert if listener contract is not found
        require(index >= 0, "L42");

        // Else remove listener contract from array
        transfersListeners[uint256(index)] = transfersListeners[transfersListenersLength - 1];
        transfersListeners.pop();
    }

    /**
     * @dev Required override of decimals() which is implemented by both ERC20Upgradeable
     * and ERC20WrapperUpgradeable parent contracts.
     * The ERC20WrapperUpgradeable version is preferred because it mirrors the decimals
     * amount of the underlying wrapped token.
     * @inheritdoc ERC20WrapperUpgradeable
     */
    function decimals() public view override(ERC20Upgradeable, ERC20WrapperUpgradeable) returns (uint8) {
        return ERC20WrapperUpgradeable.decimals();
    }

    /**
     * @dev Public implementation of _rewardsOf() allowing off-chain frontends to easily
     * compute the unclaimed rewards of a given account (e.g., used in growth/revenue charts
     * of DApp's dashboard).
     * @param account The account to check the rewards of
     * @return The amount of account's unclaimed rewards
     */
    function unmintedRewardsOf(address account) public view returns (uint256) {
        return _rewardsOf(account, true);
    }

    /**
     * @dev Returns the "real" balance of an account, i.e., excluding its not yet
     * minted rewards.
     * @param account The account to check balance for
     * @return The real balance of the account
     */
    function realBalanceOf(address account) public view returns (uint256) {
        return super.balanceOf(account);
    }

    /**
     * @dev Override of ERC20Upgradeable.balanceOf() that returns the total amount of
     * L-Tokens that belong to the account, including its unclaimed rewards.
     * @inheritdoc ERC20Upgradeable
     */
    function balanceOf(address account) public view override returns (uint256) {
        return realBalanceOf(account) + unmintedRewardsOf(account);
    }

    /**
     * @dev Returns the "real" amount of existing L-Tokens, i.e., excluding not yet minted
     * owner fees and L-Tokens currently queued in the withdrawal queue.
     * @return The real balance of the account
     */
    function realTotalSupply() public view returns (uint256) {
        return super.totalSupply();
    }

    /**
     * @dev Override of ERC20Upgradeable.totalSupply() that also includes:
     * - L-Tokens currently queued in the withdrawal queue
     * - L-Tokens currently frozen
     * - not yet minted owner's unclaimed withdrawal fees
     * @inheritdoc ERC20Upgradeable
     */
    function totalSupply() public view override returns (uint256) {
        return realTotalSupply() + totalQueued + unclaimedFees;
    }

    /**
     * @dev Override of RecoverableUpgradeable.recoverERC20() that prevents recovered
     * token from being the underlying token.
     * @inheritdoc RecoverableUpgradeable
     */
    function recoverERC20(address tokenAddress, uint256 amount) public override onlyOwner {
        // Ensure the token is not the underlying token
        require(tokenAddress != address(underlying()), "L43");
        super.recoverERC20(tokenAddress, amount);
    }

    /**
     * @dev Allows recovering underlying token accidentally sent to contract. To prevent
     * owner from draining funds from the contract, this function only allows recovering
     * "unusable" underlying tokens, i.e., tokens that have not been deposited through
     * legit ways. See "LToken > Underlying token recovery" section of whitepaper.
     */
    function recoverUnderlying() external onlyOwner {
        // Compute the amount of underlying tokens that can be recovered by taking the difference
        // between the contract's underlying balance and the total amount deposit by users
        uint256 recoverableAmount = underlying().balanceOf(address(this)) - usableUnderlyings;

        // Revert if there are no recoverable $LDY
        require(recoverableAmount > 0, "L44");

        // Else transfer the recoverable underlying to the owner
        super.recoverERC20(address(underlying()), recoverableAmount);
    }

    /**
     * @dev Implementation of InvestUpgradeable._investmentOf() require by InvestUpgradeable
     * contract to calculate rewards of a given account. In this contract the investment of
     * an account is equal to its real balance (excluding not yet claimed rewards).
     * @inheritdoc InvestUpgradeable
     */
    function _investmentOf(address account) internal view override returns (uint256) {
        return realBalanceOf(account);
    }

    /**
     * @dev Implementation of InvestUpgradeable._claimRewards(). If implemented the parent
     * contract will use it to claim rewards before each period reset. See the function
     * documentation in the parent contract for more details.
     * Note that:
     * - InvestUpgradeable contract already ensure that amount > 0
     * @inheritdoc InvestUpgradeable
     */
    function _distributeRewards(address account, uint256 amount) internal override returns (bool) {
        // Retrieve balance before minting rewards
        uint256 balanceBefore = realBalanceOf(account);

        // Inform listeners of the rewards minting
        emit MintedRewardsEvent(account, balanceBefore, amount);

        // Mint L-Tokens rewards to account
        _mint(account, amount);

        // Return true indicating to InvestUpgradeable that the rewards have been claimed
        return true;
    }

    /**
     * @dev Override of ERC20._beforeTokenTransfer() hook resetting investment periods
     * of each involved account that is not the zero address.
     * Note that we don't check for not paused contract and not blacklisted accounts
     * as this is already done in ERC20BaseUpgradeable parent contract.
     * @inheritdoc ERC20BaseUpgradeable
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override(ERC20Upgradeable, ERC20BaseUpgradeable) {
        ERC20BaseUpgradeable._beforeTokenTransfer(from, to, amount);

        // Reset investment period of involved accounts
        if (from != address(0)) _beforeInvestmentChange(from, true);
        if (to != address(0)) _beforeInvestmentChange(to, true);

        // In some L-Token are burned or minted, inform listeners of a TVL change
        if (from == address(0) || to == address(0)) emit TVLUpdateEvent(totalSupply());
    }

    /**
     * @dev Override of ERC20._afterTokenTransfer() hook that triggers onLTokenTransfer()
     * functions of all transfer listeners.
     * Note that we don't check for not paused contract and not blacklisted accounts
     * as this is already done in _beforeTokenTransfer().
     * @inheritdoc ERC20Upgradeable
     */
    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        super._afterTokenTransfer(from, to, amount);

        // Trigger onLTokenTransfer() functions of all transfers listeners
        for (uint256 i = 0; i < transfersListeners.length; i++) {
            transfersListeners[i].onLTokenTransfer(from, to, amount);
        }
    }

    /**
     * @dev Calculates the amount of underlying token that is expected to be retained on
     * the contract (from retention rate).
     * @return amount The expected amount of retained underlying tokens
     */
    function getExpectedRetained() public view returns (uint256 amount) {
        // Cache invested token decimals number
        uint256 d = SUD.decimalsOf(address(invested()));

        // Compute expected retained amount
        uint256 totalSupplySUD = SUD.fromAmount(totalSupply(), d);
        uint256 retentionRateSUD = SUD.fromRate(retentionRateUD7x3, d);
        uint256 expectedRetainedSUD = (totalSupplySUD * retentionRateSUD) / SUD.fromInt(100, d);
        return SUD.toAmount(expectedRetainedSUD, d);
    }

    /**
     * @dev Transfers every underlying token exceeding the retention rate to the fund wallet.
     * Note that there is a 10000 tokens threshold to avoid transferring small amounts of
     * underlying frequently when the retention rate is close to 100%.
     * This threshold helps saving gas by lowering the number of transfers (and thus the number
     * of chain writes).
     */
    function _transferExceedingToFund() internal {
        // Calculate the exceeding amount of underlying tokens
        uint256 expectedRetained = getExpectedRetained();
        uint256 exceedingAmount = usableUnderlyings > expectedRetained
            ? usableUnderlyings - expectedRetained
            : 0;

        // Decrease usable underlyings amount accordingly
        usableUnderlyings -= exceedingAmount;

        // Transfer the exceeding amount to the fund wallet
        underlying().safeTransfer(fund, exceedingAmount);
    }

    /**
     * @dev Overrides of ERC20WrapperUpgradeable.withdrawTo() and depositFor() functions
     * that prevents any usage of them (forbidden).
     * Instead, use _withdrawTo() and super.depositFor() internally or withdraw() and
     * deposit() externally.
     * @inheritdoc ERC20WrapperUpgradeable
     */
    function withdrawTo(address account, uint256 amount) public pure override returns (bool) {
        account; // Silence unused variable compiler warning
        amount;
        revert("L45");
    }

    function depositFor(address account, uint256 amount) public pure override returns (bool) {
        account; // Silence unused variable compiler warning
        amount;
        revert("L46");
    }

    /**
     * @dev Override of ERC20Wrapper.depositFor() that support reset of investment period
     * and transfer of underlying tokens exceeding the retention to the fund wallet.
     * @param amount The amount of underlying tokens to deposit
     */
    function deposit(uint256 amount) public whenNotPaused notBlacklisted(_msgSender()) {
        // Ensure the account has enough underlying tokens to deposit
        require(underlying().balanceOf(_msgSender()) >= amount, "L47");

        // Receive deposited underlying tokens and mint L-Tokens to the account in a 1:1 ratio
        super.depositFor(_msgSender(), amount);

        // Update usable underlyings balance accordingly
        usableUnderlyings += amount;

        // Inform listeners of the deposit activity event
        emit ActivityEvent(NO_ID, _msgSender(), Action.Deposit, amount, amount, Status.Success);

        // Transfer funds exceeding the retention rate to fund wallet
        _transferExceedingToFund();
    }

    /**
     * @dev This function computes withdrawal fees and withdrawn amount for a given account
     * and request amount.
     * @param account The account to withdraw tokens for
     * @param amount The request amount of tokens to withdraw
     *
     */
    function getWithdrawnAmountAndFees(
        address account,
        uint256 amount
    ) public view returns (uint256 withdrawnAmount, uint256 fees) {
        // If the account is eligible to staking tier 2, no fees are applied
        if (ldyStaking.tierOf(account) >= 2) return (amount, 0);

        // Cache invested token decimals number
        uint256 d = SUD.decimalsOf(address(invested()));

        // Else calculate withdrawal fees as well as final withdrawn amount
        uint256 amountSUD = SUD.fromAmount(amount, d);
        uint256 feesRateSUD = SUD.fromRate(feesRateUD7x3, d);
        uint256 feesSUD = (amountSUD * feesRateSUD) / SUD.fromInt(100, d);
        fees = SUD.toAmount(feesSUD, d);
        withdrawnAmount = amount - fees;
    }

    /**
     * @dev This withdrawal function is to be called by DApp users directly and will try
     * to instaneously withdraw a given amount of underlying tokens. If the contract
     * currently cannot cover the request, this function will revert.
     *
     * Note: In order to save gas to users, the frontends built on this contract should
     * propose calling this function only when it has been verified that it will not revert.
     * @param amount The amount of tokens to withdraw
     */
    function instantWithdrawal(uint256 amount) external whenNotPaused notBlacklisted(_msgSender()) {
        // Ensure the account holds has enough funds to withdraw
        require(amount <= balanceOf(_msgSender()), "L48");

        // Does contract can cover the request + already queued requests ?
        bool cond1 = totalQueued + amount <= usableUnderlyings;

        // Does caller is eligible to 2nd staking tier and contract can cover the request ?
        bool cond2 = ldyStaking.tierOf(_msgSender()) >= 2 && amount <= usableUnderlyings;

        // Revert if request cannot be processed instantaneously
        if (!(cond1 || cond2)) revert("L49");

        // Else, retrieve withdrawal fees and amount excluding fees
        (uint256 withdrawnAmount, uint256 fees) = getWithdrawnAmountAndFees(_msgSender(), amount);

        // Update the total amount of unclaimed fees
        unclaimedFees += fees;

        // Process to withdraw (burns withdrawn L-Tokens amount and transfers underlying tokens in a 1:1 ratio)
        super.withdrawTo(_msgSender(), withdrawnAmount);

        // Burn fees amount of L-Tokens from the account
        _burn(_msgSender(), fees);

        // Decrease usable underlyings balance accordingly
        usableUnderlyings -= withdrawnAmount;

        // Inform listeners of this instant withdrawal activity event
        emit ActivityEvent(
            NO_ID,
            _msgSender(),
            Action.Withdraw,
            amount,
            withdrawnAmount,
            Status.Success
        );
    }

    /**
     * @dev This withdrawal function is to be called by the withdrawer server will process
     * next queued withdrawal requests as long as the contract holds enough funds.
     * See "LToken > Withdrawals" section of whitepaper for more details.
     */
    function batchQueuedWithdraw() external onlyWithdrawer whenNotPaused {
        // Accumulators variables, to be written on-chain after the loop
        uint256 cumulatedFees = 0;
        uint256 cumulatedWithdrawnAmount = 0;
        uint256 nextRequestId = withdrawalQueueCursor;

        // Cache queue length to avoid multiple SLOADs.
        // This also avoid infinite loop in case some big requests are
        // moved at the end of the queue.
        uint256 queueLength = withdrawalQueue.length;

        // Iterate over next requests to be processed
        while (nextRequestId < queueLength) {
            // Stop processing requests if there is not enough gas left
            if (gasleft() < 200_000) break;

            // Retrieve request data
            WithdrawalRequest memory request = withdrawalQueue[nextRequestId];

            // Skip empty request (processed big request or cancelled request)
            if (request.account == address(0)) {}
            // If account has been blacklisted since request emission
            else if (isBlacklisted(request.account)) {
                // Remove request from queue
                delete withdrawalQueue[nextRequestId];

                // Append request in the frozen requests list
                frozenRequests.push(request);
            }
            // Or if request it is a big request, move it at the end of the queue for now.
            // This request will be processed manually later using bigQueuedWithdraw()
            else if (request.amount > getExpectedRetained() / 2) {
                // Remove request from queue
                delete withdrawalQueue[nextRequestId];

                // Append request at the end of the queue
                withdrawalQueue.push(request);
            }
            // Else continue request processing
            else {
                // Retrieve withdrawal fees and amount excluding fees
                (uint256 withdrawnAmount, uint256 fees) = getWithdrawnAmountAndFees(
                    request.account,
                    request.amount
                );

                // Break if the contract doesn't hold enough funds to cover the request
                if (withdrawnAmount > usableUnderlyings - cumulatedWithdrawnAmount) break;

                // Accumulate fees and withdrawn amount
                cumulatedFees += fees;
                cumulatedWithdrawnAmount += withdrawnAmount;

                // Inform listeners of this queued withdrawal processing activity event
                emit ActivityEvent(
                    int256(nextRequestId),
                    request.account,
                    Action.Withdraw,
                    request.amount,
                    withdrawnAmount,
                    Status.Success
                );

                // Remove request from queue
                delete withdrawalQueue[nextRequestId];

                // Transfer underlying tokens to request account. Burning L-Tokens is
                // not needed here because requestWithdrawal() already did it.
                // Re-entrancy check are disabled here as the request has been deleted
                // from the queue and so will be skipped.
                // slither-disable-next-line reentrancy-no-eth
                underlying().safeTransfer(request.account, withdrawnAmount);
            }

            // Increment next request ID
            nextRequestId++;
        }

        // Increase unclaimed fees with the amount of cumulated fees
        unclaimedFees += cumulatedFees;

        // Decrease usable underlyings by the cumulated amount of withdrawn underlyings
        usableUnderlyings -= cumulatedWithdrawnAmount;

        // Decrease total amount queued by the cumulated amount of withdrawal requests
        totalQueued -= cumulatedWithdrawnAmount + cumulatedFees;

        // Update new queue cursor
        withdrawalQueueCursor = nextRequestId;
    }

    /**
     * @dev This withdrawal function is to be called by the fund wallet (financial team)
     * to manually process a given big queued withdrawal request (that exceeds half of
     * the retention rate).
     * In contrast to non-big requests processing, this function will fill the request
     * from fund wallet balance directly.
     * This allows processing requests that are bigger than the retention rate while
     * never exceeding the retention rate on the contract.
     * @param requestId The big request's index to process
     */
    function bigQueuedWithdraw(uint256 requestId) external onlyFund whenNotPaused {
        // Retrieve request and ensure it exists and has not been processed yet or cancelled
        WithdrawalRequest memory request = withdrawalQueue[requestId];

        // Ensure the request emitter has not been blacklisted since request emission
        require(!isBlacklisted(request.account), "L50");

        // Ensure this is a big request
        require(request.amount > getExpectedRetained() / 2, "L51");

        // Retrieve withdrawal fees and amount excluding fees
        (uint256 withdrawnAmount, uint256 fees) = getWithdrawnAmountAndFees(
            request.account,
            request.amount
        );

        // Ensure withdrawn amount can be covered by contract + fundWallet balances
        uint256 fundBalance = underlying().balanceOf(fund);
        require(withdrawnAmount <= usableUnderlyings + fundBalance, "L52");

        // Update amount of unclaimed fees and total queued amount
        unclaimedFees += fees;
        totalQueued -= request.amount;

        // Move withdrawal queue cursor forward if request was the next request
        if (requestId == withdrawalQueueCursor) withdrawalQueueCursor++;

        // Inform listeners of this queued withdrawal processing activity event
        emit ActivityEvent(
            int256(requestId),
            request.account,
            Action.Withdraw,
            request.amount,
            withdrawnAmount,
            Status.Success
        );

        // Remove request from queue
        delete withdrawalQueue[requestId];

        // If fund balance can cover request alone
        if (withdrawnAmount <= fundBalance) {
            // Cover request from fund balance only
            underlying().safeTransferFrom(_msgSender(), request.account, withdrawnAmount);
        }
        // Else, cover request from contract balance also
        else {
            // Compute missing amount to cover request
            uint256 missingAmount = withdrawnAmount - fundBalance;

            // Decrease usable underlyings amount
            usableUnderlyings -= missingAmount;

            // Transfer entire fund balance to request account
            underlying().safeTransferFrom(_msgSender(), request.account, fundBalance);

            // Transfer missing amount from contract balance to request account
            underlying().safeTransfer(request.account, missingAmount);
        }
    }

    /**
     * @dev This withdrawal function, put the given amount request in queue to be processed
     * as soon as the contract would have enough funds to cover it.
     * The sender must attach 0.004 ETH to pre-pay the future processing gas fees paid by
     * the withdrawer wallet.
     * @param amount The amount of tokens to withdraw
     */
    function requestWithdrawal(
        uint256 amount
    ) public payable whenNotPaused notBlacklisted(_msgSender()) {
        // Ensure the account has enough funds to withdraw
        require(amount <= balanceOf(_msgSender()), "L53");

        // Ensure the requested amount doesn't overflow uint96
        require(amount <= type(uint96).max, "L54");

        // Ensure the sender attached pre-paid processing gas fees
        require(msg.value == 0.004 * 10 ** 18, "L55");

        // Create request data
        WithdrawalRequest memory request = WithdrawalRequest({
            account: _msgSender(),
            amount: uint96(amount)
        });

        // Will host the new request ID
        uint256 requestId;

        // If the account is eligible to staking tier 2 and queue cursor is not 0
        if (ldyStaking.tierOf(_msgSender()) >= 2 && withdrawalQueueCursor > 0) {
            // Append request at the beginning of the queue
            withdrawalQueueCursor--;
            requestId = withdrawalQueueCursor;
            withdrawalQueue[requestId] = request;
        }
        // Else append it at the end of the queue
        else {
            withdrawalQueue.push(request);
            requestId = withdrawalQueue.length - 1;
        }

        // Increase total amount queued
        totalQueued += amount;

        // Inform listeners of this new queued withdrawal activity event
        emit ActivityEvent(
            int256(requestId),
            _msgSender(),
            Action.Withdraw,
            amount,
            amount,
            Status.Queued
        );

        // Burn withdrawn L-Tokens amount
        _burn(_msgSender(), amount);

        // Forward pre-paid processing gas fees to the withdrawer
        (bool sent, ) = withdrawer.call{value: msg.value}("");
        require(sent, "L56");
    }

    /**
     * @dev Allows to cancel a currently queued withdrawal request. The request emitter
     * will receive back its L-Tokens and no fees will be charged.
     * Note that we don't check if the msg.sender is blacklisted here because
     * @param requestId The index of the withdrawal request to remove
     */
    function cancelWithdrawalRequest(
        uint256 requestId
    ) public whenNotPaused notBlacklisted(_msgSender()) {
        // Retrieve request data
        WithdrawalRequest memory request = withdrawalQueue[requestId];

        // Ensure it belongs to caller or the caller is the withdrawer
        require(_msgSender() == request.account, "L57");

        // Decrease total amount queued
        totalQueued -= request.amount;

        // Delete the withdrawal request from queue
        delete withdrawalQueue[requestId];

        // Inform listeners of this cancelled withdrawal request activity event
        emit ActivityEvent(
            int256(requestId),
            request.account,
            Action.Withdraw,
            request.amount,
            request.amount,
            Status.Cancelled
        );

        // Mint back L-Tokens to account and update total amount queued
        _mint(request.account, uint256(request.amount));
    }

    /**
     * @dev This function allows fund wallet to send underlying tokens to this contract.
     * Security note: To ensure this contract will never hold more than the retention
     * rate, this function will revert if the new contract balance exceeds it.
     * @param amount The amount of underlying tokens to send
     */
    function repatriate(uint256 amount) external onlyFund whenNotPaused {
        // Ensure the fund wallet has enough funds to repatriate
        require(amount <= underlying().balanceOf(fund), "L58");

        // Calculate new balance
        uint256 newBalance = usableUnderlyings + amount;

        // Ensure the new balance doesn't exceed the retention rate
        require(newBalance <= getExpectedRetained(), "L59");

        // Increase usable underlyings amount
        usableUnderlyings += amount;

        // Transfer amount from fund wallet to contract
        underlying().safeTransferFrom(_msgSender(), address(this), amount);
    }

    /**
     * @dev Used by contract owner to claim fees generated from successful withdrawal.
     */
    function claimFees() external onlyOwner {
        // Ensure their are some fees to claim
        require(unclaimedFees > 0, "L60");

        // Ensure the contract holds enough underlying tokens
        require(usableUnderlyings >= unclaimedFees, "L61");

        // Decrease usable underlyings amount accordingly
        usableUnderlyings -= unclaimedFees;

        // Store fees amount in memory and reset unclaimed fees amount
        uint256 fees = unclaimedFees;
        unclaimedFees = 0;

        // Transfer unclaimed fees to owner
        underlying().safeTransfer(owner(), fees);
    }
}