pragma solidity ^0.4.4;

import "./dependencies/Assertive.sol";

/// @title Simple multi signature contract
/// @author Melonport AG <team@melonport.com>
/// @notice Allows multiple owners to agree on any given transaction before execution
/// @notice Inspired by https://github.com/ethereum/dapp-bin/blob/master/wallet/wallet.sol
contract MultiSigWallet is Assertive {

    // TYPES

    struct Transaction {
        address destination;
        uint value;
        bytes data;
        uint nonce;
        bool executed;
    }

    // FILEDS

    // Fields that are only changed in constructor
    address[] multiSigOwners; // Addresses with signing authority
    mapping (address => bool) public isMultiSigOwner; // Has address siging authority
    uint public requiredSignatures; // Number of required signatures to execute a transaction

    // Fields that can be changed by functions
    bytes32[] transactionList; // Array of transactions hashes
    mapping (bytes32 => Transaction) public transactions; // Maps transaction hash [bytes32[ to a Transaction [struct]
    mapping (bytes32 => mapping (address => bool)) public confirmations; // Whether [bool] transaction hash [bytes32] has been confirmed by owner [address]

    // EVENTS

    event Confirmation(address sender, bytes32 txHash);
    event Revocation(address sender, bytes32 txHash);
    event Submission(bytes32 txHash);
    event Execution(bytes32 txHash);
    event Deposit(address sender, uint value);

    // MODIFIERS

    modifier is_multi_sig_owners_signature(bytes32 txHash, uint8[] v, bytes32[] r, bytes32[] s) {
        for (uint i = 0; i < v.length; i++)
            assert(isMultiSigOwner[ecrecover(txHash, v[i], r[i], s[i])]);
        _;
    }

    modifier only_multi_sig_owner {
        assert(isMultiSigOwner[msg.sender]);
        _;
    }

    modifier msg_sender_has_confirmed(bytes32 txHash) {
        assert(confirmations[txHash][msg.sender]);
        _;
    }

    modifier msg_sender_has_not_confirmed(bytes32 txHash) {
        assert(!confirmations[txHash][msg.sender]);
        _;
    }

    modifier transaction_is_not_executed(bytes32 txHash) {
        assert(!transactions[txHash].executed);
        _;
    }

    modifier address_not_null(address destination) {
        assert(destination != 0 || destination != 0x0);
        _;
    }

    modifier valid_amount_of_required_signatures(uint ownerCount, uint required) {
        assert(ownerCount != 0);
        assert(required != 0);
        assert(required <= ownerCount);
        _;
    }

    modifier transaction_is_confirmed(bytes32 txHash) {
        assert(isConfirmed(txHash));
        _;
    }

    // CONSTANT METHODS

    function isConfirmed(bytes32 txHash) constant returns (bool) { return requiredSignatures <= confirmationCount(txHash); }

    function confirmationCount(bytes32 txHash) constant returns (uint count)
    {
        for (uint i = 0; i < multiSigOwners.length; i++)
            if (confirmations[txHash][multiSigOwners[i]])
                count += 1;
    }

    function getPendingTransactions() constant returns (bytes32[]) { return filterTransactions(true); }

    function getExecutedTransactions() constant returns (bytes32[]) { return filterTransactions(false); }

    function filterTransactions(bool isPending) constant returns (bytes32[] transactionListFiltered)
    {
        bytes32[] memory transactionListTemp = new bytes32[](transactionList.length);
        uint count = 0;
        for (uint i = 0; i < transactionList.length; i++)
            if (   isPending && !transactions[transactionList[i]].executed
                || !isPending && transactions[transactionList[i]].executed)
            {
                transactionListTemp[count] = transactionList[i];
                count += 1;
            }
        transactionListFiltered = new bytes32[](count);
        for (i = 0; i < count; i++)
            if (transactionListTemp[i] > 0)
                transactionListFiltered[i] = transactionListTemp[i];
    }

    // NON-CONSTANT INTERNAL METHODS

    /// Pre: Transaction has not already been submitted
    /// Post: New transaction in transactions and transactionList fields
    function addTransaction(address destination, uint value, bytes data, uint nonce)
        internal
        address_not_null(destination)
        returns (bytes32 txHash)
    {
        txHash = sha3(destination, value, data, nonce);
        if (transactions[txHash].destination == 0) {
            transactions[txHash] = Transaction({
                destination: destination,
                value: value,
                data: data,
                nonce: nonce,
                executed: false
            });
            transactionList.push(txHash);
            Submission(txHash);
        }
    }

    /// Pre: Transaction has not already been approved by msg.sender
    /// Post: Transaction w transaction hash: txHash approved by msg.sender
    function addConfirmation(bytes32 txHash, address owner)
        internal
        msg_sender_has_not_confirmed(txHash)
    {
        confirmations[txHash][owner] = true;
        Confirmation(owner, txHash);
    }

    // NON-CONSTANT PUBLIC METHODS

    /// Pre: Multi sig owner; Transaction has not already been submited
    /// Post: Transaction confirmed for multi sig owner
    function submitTransaction(address destination, uint value, bytes data, uint nonce)
        returns (bytes32 txHash)
    {
        txHash = addTransaction(destination, value, data, nonce);
        confirmTransaction(txHash);
    }

    /// Pre: Multi sig owner(s) signature(s); Transaction has not already been submited
    /// Post: Transaction confirmed for multi sig owner(s)
    function submitTransactionWithSignatures(address destination, uint value, bytes data, uint nonce, uint8[] v, bytes32[] r, bytes32[] s)
        returns (bytes32 txHash)
    {
        txHash = addTransaction(destination, value, data, nonce);
        confirmTransactionWithSignatures(txHash, v, r, s);
    }

    /// Pre: Multi sig owner
    /// Post: Confirm approval to execute transaction
    function confirmTransaction(bytes32 txHash)
        only_multi_sig_owner
    {
        addConfirmation(txHash, msg.sender);
        if (isConfirmed(txHash))
            executeTransaction(txHash);
    }

    /// Pre: Anyone with valid mutli sig owner(s) signature(s)
    /// Post: Confirms approval to execute transaction of signing multi sig owner(s)
    function confirmTransactionWithSignatures(bytes32 txHash, uint8[] v, bytes32[] r, bytes32[] s)
        is_multi_sig_owners_signature(txHash, v, r, s)
    {
        for (uint i = 0; i < v.length; i++)
            addConfirmation(txHash, ecrecover(txHash, v[i], r[i], s[i]));
        if (isConfirmed(txHash))
            executeTransaction(txHash);
    }

    /// Pre: Multi sig owner who has confirmed pending transaction
    /// Post: Revokes approval of multi sig owner
    function revokeConfirmation(bytes32 txHash)
        only_multi_sig_owner
        msg_sender_has_confirmed(txHash)
        transaction_is_not_executed(txHash)
    {
        confirmations[txHash][msg.sender] = false;
        Revocation(msg.sender, txHash);
    }

    /// Pre: Multi sig owner quorum has been reached
    /// Post: Executes transaction from this contract account
    function executeTransaction(bytes32 txHash)
        transaction_is_not_executed(txHash)
        transaction_is_confirmed(txHash)
    {
        Transaction tx = transactions[txHash];
        tx.executed = true;
        assert(tx.destination.call.value(tx.value)(tx.data));
        Execution(txHash);
    }

    /// Pre: All fields, except { multiSigOwners, requiredSignatures } are valid
    /// Post: All fields, including { multiSigOwners, requiredSignatures } are valid
    function MultiSigWallet(address[] setOwners, uint setRequiredSignatures)
        valid_amount_of_required_signatures(setOwners.length, setRequiredSignatures)
    {
        for (uint i = 0; i < setOwners.length; i++)
            isMultiSigOwner[setOwners[i]] = true;
        multiSigOwners = setOwners;
        requiredSignatures = setRequiredSignatures;
    }

    /// Pre: All fields, including { multiSigOwners, requiredSignatures } are valid
    /// Post: Received sent funds into wallet
    function() payable { Deposit(msg.sender, msg.value); }

}
