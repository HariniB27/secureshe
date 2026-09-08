// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title SecureSheRegistry
/// @notice Anchors a SHA-256 evidence hash + status for each SecureShe complaint on-chain.
///         Only the authorized backend wallet (the deployer) may write. Anyone can read a
///         complaint's record to verify it hasn't been altered.
contract SecureSheRegistry {
    address public owner;

    struct ComplaintRecord {
        string evidenceHash;   // SHA-256 hash of the evidence file (hex string)
        uint256 timestamp;     // block.timestamp when logged
        string status;         // SUBMITTED / UNDER REVIEW / RESOLVED
        bool exists;           // guards against overwriting/looking up an unset record
    }

    mapping(string => ComplaintRecord) private records; // complaintId => record

    event ComplaintLogged(string indexed complaintId, string evidenceHash, uint256 timestamp);
    event StatusUpdated(string indexed complaintId, string newStatus, uint256 timestamp);

    modifier onlyOwner() {
        require(msg.sender == owner, "SecureSheRegistry: caller is not authorized");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function logComplaint(string calldata complaintId, string calldata evidenceHash) external onlyOwner {
        require(!records[complaintId].exists, "SecureSheRegistry: complaint already logged");
        records[complaintId] = ComplaintRecord({
            evidenceHash: evidenceHash,
            timestamp: block.timestamp,
            status: "SUBMITTED",
            exists: true
        });
        emit ComplaintLogged(complaintId, evidenceHash, block.timestamp);
    }

    function updateStatus(string calldata complaintId, string calldata newStatus) external onlyOwner {
        require(records[complaintId].exists, "SecureSheRegistry: complaint not found");
        records[complaintId].status = newStatus;
        emit StatusUpdated(complaintId, newStatus, block.timestamp);
    }

    function getComplaint(string calldata complaintId)
        external
        view
        returns (string memory evidenceHash, uint256 timestamp, string memory status, bool exists)
    {
        ComplaintRecord memory r = records[complaintId];
        return (r.evidenceHash, r.timestamp, r.status, r.exists);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "SecureSheRegistry: zero address");
        owner = newOwner;
    }
}
