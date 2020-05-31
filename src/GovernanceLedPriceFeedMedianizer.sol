pragma solidity >=0.5.15;

contract Logging {
    event LogNote(
        bytes4   indexed  sig,
        address  indexed  usr,
        bytes32  indexed  arg1,
        bytes32  indexed  arg2,
        bytes             data
    ) anonymous;

    modifier emitLog {
        _;
        assembly {
            // log an 'anonymous' event with a constant 6 words of calldata
            // and four indexed topics: selector, caller, arg1 and arg2
            let mark := msize                         // end of memory ensures zero
            mstore(0x40, add(mark, 288))              // update free memory pointer
            mstore(mark, 0x20)                        // bytes type data offset
            mstore(add(mark, 0x20), 224)              // bytes size (padded)
            calldatacopy(add(mark, 0x40), 0, 224)     // bytes payload
            log4(mark, 288,                           // calldata
                 shl(224, shr(224, calldataload(0))), // msg.sig
                 caller,                              // msg.sender
                 calldataload(4),                     // arg1
                 calldataload(36)                     // arg2
                )
        }
    }
}

contract GovernanceLedPriceFeedMedianizer is Logging {
    // --- Auth ---
    mapping (address => uint) public authorizedAccounts;
    /**
     * @notice Add auth to an account
     * @param account Account to add auth to
     */
    function addAuthorization(address account) external emitLog isAuthorized {
        authorizedAccounts[account] = 1;
    }
    /**
     * @notice Remove auth from an account
     * @param account Account to remove auth from
     */
    function removeAuthorization(address account) external emitLog isAuthorized {
        authorizedAccounts[account] = 0;
    }
    /**
    * @notice Checks whether msg.sender can call an authed function
    **/
    modifier isAuthorized {
        require(authorizedAccounts[msg.sender] == 1, "GovernanceLedPriceFeedMedianizer/account-not-authorized");
        _;
    }

    uint128 private medianPrice;

    uint32  public lastUpdateTime;
    uint256 public quorum = 1;

    bytes32 public constant symbol = "ethusd"; // You want to change this every deployment

    // Authorized oracles, set by an auth
    mapping (address => uint256) public whitelistedOracles;

    // Mapping for at most 256 oracles
    mapping (uint8 => address) public oracleAddresses;

    event LogMedianPrice(uint256 medianPrice, uint256 lastUpdateTime);

    constructor() public {
        authorizedAccounts[msg.sender] = 1;
    }

    function read() external view returns (uint256) {
        require(medianPrice > 0, "GovernanceLedPriceFeedMedianizer/invalid-price-feed");
        return medianPrice;
    }

    function getResultWithValidity() external view returns (uint256,bool) {
        return (medianPrice, medianPrice > 0);
    }

    function recoverSigner(uint256 price_, uint256 updateTimestamp_, uint8 v, bytes32 r, bytes32 s) internal pure returns (address) {
        return ecrecover(
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", keccak256(abi.encodePacked(price_, updateTimestamp_, symbol)))),
            v, r, s
        );
    }

    // ONM compatibility
    function updateResult() external returns (uint) {
        require(medianPrice > 0, "GovernanceLedPriceFeedMedianizer/invalid-price-feed");
        return medianPrice;
    }

    function updateResult(
        uint256[] calldata prices_, uint256[] calldata updateTimestamps_,
        uint8[] calldata v, bytes32[] calldata r, bytes32[] calldata s) external
    {
        require(prices_.length == quorum, "GovernanceLedPriceFeedMedianizer/quorum-too-low");

        uint256 bloom = 0;
        uint256 last = 0;
        uint256 zzz = lastUpdateTime;

        for (uint i = 0; i < prices_.length; i++) {
            // Validate the prices were signed by an authorized oracle
            address signer = recoverSigner(prices_[i], updateTimestamps_[i], v[i], r[i], s[i]);
            // Check that signer is an oracle
            require(whitelistedOracles[signer] == 1, "GovernanceLedPriceFeedMedianizer/invalid-oracle");
            // Price feed timestamp greater than last medianizer time
            require(updateTimestamps_[i] > zzz, "GovernanceLedPriceFeedMedianizer/stale-message");
            // Check for ordered prices
            require(prices_[i] >= last, "GovernanceLedPriceFeedMedianizer/messages-not-in-order");
            last = prices_[i];
            // Bloom filter for signer uniqueness
            uint8 sl = uint8(uint256(signer) >> 152);
            require((bloom >> sl) % 2 == 0, "GovernanceLedPriceFeedMedianizer/oracle-already-signed");
            bloom += uint256(2) ** sl;
        }

        medianPrice    = uint128(prices_[prices_.length >> 1]);
        lastUpdateTime = uint32(block.timestamp);

        emit LogMedianPrice(medianPrice, lastUpdateTime);
    }

    function addOracles(address[] calldata orcls) external emitLog isAuthorized {
        for (uint i = 0; i < orcls.length; i++) {
            require(orcls[i] != address(0), "GovernanceLedPriceFeedMedianizer/no-oracle-0");
            uint8 s = uint8(uint256(orcls[i]) >> 152);
            require(oracleAddresses[s] == address(0), "GovernanceLedPriceFeedMedianizer/signer-already-exists");
            whitelistedOracles[orcls[i]] = 1;
            oracleAddresses[s] = orcls[i];
        }
    }

    function removeOracles(address[] calldata orcls) external emitLog isAuthorized {
       for (uint i = 0; i < orcls.length; i++) {
            whitelistedOracles[orcls[i]] = 0;
            oracleAddresses[uint8(uint256(orcls[i]) >> 152)] = address(0);
       }
    }

    function setQuorum(uint256 quorum_) external emitLog isAuthorized {
        require(quorum_ > 0, "GovernanceLedPriceFeedMedianizer/quorum-is-zero");
        require(quorum_ % 2 != 0, "GovernanceLedPriceFeedMedianizer/quorum-not-odd-number");
        quorum = quorum_;
    }
}
