// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.0;

// Original Bank contract: formatting only; no behavior has been changed.
contract Bank {
    enum STATUS {
        SUCCESS,
        FAILURE,
        CANCELLED
    }

    mapping(address => STATUS) status;
    mapping(address => uint256) deposits;

    function deposit() public payable {
        deposits[msg.sender] += msg.value;
        if (deposits[msg.sender] > 1 ether) {
            status[msg.sender] = STATUS.SUCCESS;
        }
    }

    function withdraw() public {
        uint256 bal = address(this).balance;
        require(status[msg.sender] == STATUS.SUCCESS);
        (bool s,) = msg.sender.call{value: bal}("");
        require(s);
    }
}
