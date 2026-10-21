// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "../src/Bank.sol";

// Minimal Foundry cheatcodes. No external testing library is required.
interface Vm {
    function deal(address account, uint256 balance) external;
    function prank(address sender) external;
    function store(address target, bytes32 slot, bytes32 value) external;
    function load(address target, bytes32 slot) external returns (bytes32);
    function expectRevert() external;
}

// This contract rejects ETH. It lets us verify that a failed payout reverts.
contract RejectEtherReceiver {
    Bank public bank;
    constructor(Bank bank_) { bank = bank_; }
    function withdrawFromBank() external { bank.withdraw(); }
    receive() external payable { revert("Receiver refuses ETH"); }
}

// This contract calls withdraw() a second time during the first payout.
contract ReentrantReceiver {
    Bank public bank;
    uint256 public numberOfPayoutCallbacks;
    bool private alreadyReentered;

    constructor(Bank bank_) { bank = bank_; }
    function withdrawFromBank() external { bank.withdraw(); }
    receive() external payable {
        numberOfPayoutCallbacks += 1;
        if (!alreadyReentered) {
            alreadyReentered = true;
            bank.withdraw();
        }
    }
}

contract BankTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    Bank private bank;

    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant CHARLIE = address(0xC0FFEE);

    // Only FAILURE and CANCELLED require direct storage setup. The original
    // contract has no callable function that can enter either of these states.

    uint256 private constant STATUS_MAPPING_SLOT = 0;
    uint256 private constant FAILURE = 1;
    uint256 private constant CANCELLED = 2;

    function setUp() public {
        bank = new Bank();
        vm.deal(ALICE, 20 ether);
        vm.deal(BOB, 20 ether);
        vm.deal(CHARLIE, 20 ether);
    }

    function depositAs(address depositor, uint256 amount) private {
        vm.prank(depositor);
        bank.deposit{value: amount}();
    }

    function setUnreachableStatusForTest(address account, uint256 status) private {
        // A testing-only setup technique; production callers cannot do this.
        bytes32 accountStatusSlot = keccak256(abi.encode(account, STATUS_MAPPING_SLOT));
        vm.store(address(bank), accountStatusSlot, bytes32(status));
    }

    function assertEqual(uint256 actual, uint256 expected, string memory explanation) private pure {
        require(actual == expected, explanation);
    }

    function test_NewBankStartsWithZeroEther() public view {
        // A newly deployed bank has received no payments.
        assertEqual(address(bank).balance, 0, "Fresh bank must have no ETH");
    }

    function test_DepositingZeroEtherDoesNotIncreaseBankBalance() public {
        // Act: Alice sends a zero-value deposit.
        depositAs(ALICE, 0);
        // Assert: the bank receives no ETH.
        assertEqual(address(bank).balance, 0, "Zero deposit must not fund bank");
    }

    function test_TwoSmallDepositsAccumulateInBankBalance() public {
        // Act: Alice sends 0.3 ETH followed by 0.4 ETH.
        depositAs(ALICE, 0.3 ether);
        depositAs(ALICE, 0.4 ether);
        // Assert: both transfers remain in the bank.
        assertEqual(address(bank).balance, 0.7 ether, "Bank must hold both payments");
    }

    function test_ExactlyOneEtherDoesNotQualifyAnAccountMarkedFailure() public {
        // Arrange: the contract never sets FAILURE by itself, so force this
        // otherwise unreachable precondition using a test-only storage write.
        setUnreachableStatusForTest(ALICE, FAILURE);
        depositAs(ALICE, 1 ether);
        // Act and assert: exactly 1 ETH does not cross the strict > threshold.
        vm.expectRevert();
        vm.prank(ALICE);
        bank.withdraw();
        assertEqual(address(bank).balance, 1 ether, "Rejected withdraw must leave ETH in bank");
    }

    function test_OneEtherPlusOneWeiQualifiesAnAccountPreviouslyMarkedFailure() public {
        // Arrange: set FAILURE to make a successful threshold transition observable.
        setUnreachableStatusForTest(ALICE, FAILURE);
        depositAs(ALICE, 1 ether + 1);
        uint256 aliceBefore = ALICE.balance;
        // Act: withdrawal now succeeds, because deposit changed status to SUCCESS.
        vm.prank(ALICE);
        bank.withdraw();
        assertEqual(ALICE.balance, aliceBefore + 1 ether + 1, "Above-threshold depositor must receive payout");
        assertEqual(address(bank).balance, 0, "Successful payout must empty bank");
    }

    function test_CumulativeDepositsQualifyAccountOnlyAfterThresholdCrossing() public {
        // Arrange: CANCELLED cannot be reached through the public interface.
        setUnreachableStatusForTest(ALICE, CANCELLED);
        depositAs(ALICE, 0.6 ether);
        // Assert: Alice still cannot withdraw below the threshold.
        vm.expectRevert();
        vm.prank(ALICE);
        bank.withdraw();
        assertEqual(address(bank).balance, 0.6 ether, "Failed withdrawal must preserve first deposit");
        // Act: cumulative deposit now exceeds 1 ETH.
        depositAs(ALICE, 0.5 ether);
        uint256 aliceBefore = ALICE.balance;
        vm.prank(ALICE);
        bank.withdraw();
        // Assert: threshold transition permits withdrawing the 1.1 ETH pool.
        assertEqual(ALICE.balance, aliceBefore + 1.1 ether, "Crossing threshold must permit withdrawal");
        assertEqual(address(bank).balance, 0, "Successful withdrawal must drain bank");
    }

    function test_TwoDepositorsFundTheSamePooledBankBalance() public {
        // Act: Alice and Bob deposit distinct amounts.
        depositAs(ALICE, 0.8 ether);
        depositAs(BOB, 1.5 ether);
        // Assert: their ETH is held in the same bank contract.
        assertEqual(address(bank).balance, 2.3 ether, "Bank must hold both depositors' ETH");
    }

    function test_BUG_StrangerCanWithdrawAllEtherWithoutEverDepositing() public {
        // Arrange: Alice deposits, but Bob has never deposited.
        depositAs(ALICE, 2 ether);
        uint256 bobEtherBefore = BOB.balance;
        // Act: Bob calls withdraw(). The unset enum mapping equals SUCCESS.
        vm.prank(BOB);
        bank.withdraw();
        // Assert the vulnerability, NOT the intended secure behavior.
        assertEqual(BOB.balance, bobEtherBefore + 2 ether, "BUG: stranger steals Alice's ETH");
        assertEqual(address(bank).balance, 0, "BUG: bank is entirely drained");
    }

    function test_BUG_OneEligibleDepositorCanWithdrawSomeoneElsesEther() public {
        // Arrange: Alice qualifies; Bob also has funds in the shared bank.
        depositAs(ALICE, 1.1 ether);
        depositAs(BOB, 0.9 ether);
        uint256 aliceEtherBefore = ALICE.balance;
        // Act: Alice withdraws her supposed entitlement.
        vm.prank(ALICE);
        bank.withdraw();
        // Assert: withdraw() pays total contract ETH, not Alice's 1.1 ETH.
        assertEqual(ALICE.balance, aliceEtherBefore + 2 ether, "BUG: Alice takes Bob's 0.9 ETH too");
        assertEqual(address(bank).balance, 0, "BUG: bank has no ETH left to pay Bob");
    }

    function test_WithdrawalRevertsForAccountExplicitlyMarkedFailure() public {
        // Arrange: storage-only test setup is needed because no public setter exists.
        depositAs(ALICE, 0.5 ether);
        setUnreachableStatusForTest(ALICE, FAILURE);
        // Act and assert: FAILURE does not pass withdraw's require condition.
        vm.expectRevert();
        vm.prank(ALICE);
        bank.withdraw();
        assertEqual(address(bank).balance, 0.5 ether, "Revert must preserve funds");
    }

    function test_WithdrawalRevertsForAccountExplicitlyMarkedCancelled() public {
        // Arrange: set CANCELLED directly, which public contract methods cannot do.
        depositAs(ALICE, 0.5 ether);
        setUnreachableStatusForTest(ALICE, CANCELLED);
        // Act and assert: CANCELLED is not SUCCESS, so withdrawal reverts.
        vm.expectRevert();
        vm.prank(ALICE);
        bank.withdraw();
        assertEqual(address(bank).balance, 0.5 ether, "Cancelled withdrawal must preserve ETH");
    }

    function test_PayoutRevertsIfRecipientRejectsEther() public {
        // Arrange: Alice funds the bank. The caller is a contract rejecting ETH.
        depositAs(ALICE, 2 ether);
        RejectEtherReceiver rejectingCaller = new RejectEtherReceiver(bank);
        // Act: its default mapping status is SUCCESS, but its receiver rejects payment.
        vm.expectRevert();
        rejectingCaller.withdrawFromBank();
        // Assert: revert rolls the payout back completely.
        assertEqual(address(bank).balance, 2 ether, "Failed send must not remove bank ETH");
    }

    function test_WithdrawWithEmptyBankSucceedsButPaysNothing() public {
        // Arrange: bank has 0 ETH, and Charlie has not deposited.
        uint256 charlieEtherBefore = CHARLIE.balance;
        // Act: default SUCCESS permits a zero-value call.
        vm.prank(CHARLIE);
        bank.withdraw();
        // Assert: no Ether was transferred.
        assertEqual(CHARLIE.balance, charlieEtherBefore, "Empty bank must pay 0 ETH");
        assertEqual(address(bank).balance, 0, "Bank must remain empty");
    }

    function test_BUG_PreviousWithdrawerCanDrainNewDepositsAgain() public {
        // Arrange: Alice becomes eligible and empties the bank once.
        depositAs(ALICE, 1.5 ether);
        vm.prank(ALICE);
        bank.withdraw();
        // Act: Bob deposits new funds; Alice withdraws again without redepositing.
        depositAs(BOB, 2 ether);
        uint256 aliceEtherBefore = ALICE.balance;
        vm.prank(ALICE);
        bank.withdraw();
        // Assert: old permissions and recorded balance never reset.
        assertEqual(ALICE.balance, aliceEtherBefore + 2 ether, "BUG: Alice drains Bob's later funds");
        assertEqual(address(bank).balance, 0, "BUG: Bob's fresh funds are gone");
    }

    function test_BUG_WithdrawAllowsNestedReentrantCall() public {
        // Arrange: Alice funds the bank; a receiver contract starts with SUCCESS status.
        depositAs(ALICE, 2 ether);
        ReentrantReceiver attacker = new ReentrantReceiver(bank);
        // Act: payout triggers receive(), which calls withdraw() again.
        attacker.withdrawFromBank();
        // Assert: two callbacks occurred, demonstrating missing reentrancy protection.
        // The nested call sends ZERO additional ETH because the outer call already
        // transferred the bank's entire balance. This is NOT proof of double payout.
        assertEqual(address(attacker).balance, 2 ether, "Attacker gets first 2 ETH payout");
        assertEqual(attacker.numberOfPayoutCallbacks(), 2, "BUG: nested withdrawal was accepted");
        assertEqual(address(bank).balance, 0, "Bank was drained by outer payment");
    }
}
