# Bank.sol — Security Findings and Remediation

Tested: Solidity 0.8.0, Foundry 1.5.1
Original contract in src/Bank.sol is unchanged except for formatting.

## Critical — B-01: Uninitialized addresses are authorized
**Cause:** `STATUS.SUCCESS` is enum index zero, and mappings return zero for unset keys. All fresh addresses therefore satisfy the withdraw authorization check.
**Proof:** `test_BUG_StrangerCanWithdrawAllEtherWithoutEverDepositing`; a non-depositor empties the bank.
**Fix:** Define `NONE` as index 0 or invert ordering; authorize only accounts with a positive recorded withdrawable balance. Do not treat status alone as a financial entitlement.

## Critical — B-02: Withdrawals pay the entire pooled balance
**Cause:** `uint bal = address(this).balance` makes any authorized withdrawal transfer everybody's deposits.
**Proof:** `test_BUG_OneEligibleDepositorCanWithdrawSomeoneElsesEther`.
**Fix:** Let `amount = deposits[msg.sender]`; require positive balance; decrement it to zero **before** transferring `amount` and verify external call success. Keep per-user accounting separate from the contract's native token balance.

## High — B-03: Deposits are never debited
**Cause:** `withdraw` does not change `deposits[msg.sender]` or the authorized status.
**Proof:** `test_BUG_PreviousWithdrawerCanDrainNewDepositsAgain`; the same account drains future depositors' funds without redepositing.
**Fix:** Use checks-effects-interactions and set claimable balance to zero before transfer. Define clearly whether the 1 ETH qualification is lifetime-based or current-balance based; revoke eligibility when necessary.

## Medium — B-04: Reentrant calls are accepted
**Cause:** No reentrancy guard and the bank calls arbitrary receiver code without first updating balances/permissions.
**Proof:** `test_BUG_WithdrawAllowsNestedReentrantCall` observes a nested withdrawal. For the present code the nested withdrawal sends 0 because the outer call has already forwarded the bank's current balance; this test **does not** prove successful double payment via reentrancy.
**Fix:** Checks-effects-interactions, plus a ReentrancyGuard for added defense.

## Medium — B-05: No way to inspect accounting or recover access
**Cause:** Both mappings are private-by-default (internal), without getters; FAILURE/CANCELLED cannot be set by normal public calls, and there is no individual withdrawal amount or receipt.
**Proof:** `test_WithdrawalRevertsForAccountExplicitlyMarkedFailure` and `test_WithdrawalRevertsForAccountExplicitlyMarkedCancelled` require deliberate test-only storage setup.
**Fix:** Add `balanceOf(address)` and well-specified status views/events; remove unused statuses or implement controlled transitions. Explicitly document the meaning of `> 1 ether` versus `>= 1 ether`.

## Additional behavior
- Exactly 1 ether does not switch a FAILURE/CANCELLED account to SUCCESS; 1 ether + 1 wei does. See the exact-threshold and one-wei-above-threshold tests.
- Zero-value deposits are accepted.
- Contract receivers that revert cause the transaction to revert.
- No `receive()` function exists to accept plain ETH transfers; ETH can nonetheless arrive outside `deposit()` via forced transfer.
- Severity assumes this is meant to be a bank holding funds from several depositors.

## Suggested secure withdrawal pseudocode

```solidity
function withdraw() external nonReentrant {
    uint256 amount = deposits[msg.sender];
    require(amount > 0, "No balance");

    deposits[msg.sender] = 0;
    // If membership is based on current account balance:
    // status[msg.sender] = STATUS.INACTIVE;

    (bool ok, ) = payable(msg.sender).call{value: amount}("");
    require(ok, "ETH transfer failed");
}
```

This withdrawal fix must be paired with a corrected enum default and a defined product policy for the 1 ETH threshold. Merely changing the enum ordering does not fix pooled-funds theft.

## Verification
```sh
forge test -vv
forge coverage --report summary
```
The regression tests labeled `_BUG` deliberately PASS by proving unsafe current behavior; after repairing the contract, replace these with tests that assert unauthorized calls revert and user funds remain isolated.

## Test design note

The readable regression suite is primarily black-box: assertions inspect transactions, contract ETH balance and recipient ETH balances, not private mappings. Only the helper `setUnreachableStatusForTest` uses `vm.store` to arrange FAILURE/CANCELLED states, which the contract itself does not expose. Consequently B-03 is demonstrated by repeated unauthorized payout, not by direct inspection of stale storage. All 15 tests pass and Foundry reports 100% line, statement, branch and function coverage for `src/Bank.sol`.
