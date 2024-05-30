// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import "./interfaces/ITradingStorage.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./interfaces/ICallbacks.sol";
import {IExecute} from "./interfaces/IExecute.sol";

contract Execute is Initializable, IExecute {
    ITradingStorage public storageT;

    uint public triggerTimeout;
    uint public tokensClaimedTotal;

    mapping(address => uint) public tokensToClaim;
    mapping(address => mapping(uint => mapping(uint => mapping(ITradingStorage.LimitOrder => TriggeredLimit))))
        public triggeredLimits;
    mapping(address => mapping(uint => mapping(uint => OpenLimitOrderType))) public override openLimitOrderTypes;
    mapping(address => uint) public tokensClaimed;

    function initialize(address _storageT) external initializer {
        storageT = ITradingStorage(_storageT);
        triggerTimeout = 5;
    }

    // Modifiers
    modifier onlyGov() {
        require(msg.sender == storageT.gov(), "GOV_ONLY");
        _;
    }
    modifier onlyTrading() {
        require(msg.sender == storageT.trading(), "TRADING_ONLY");
        _;
    }
    modifier onlyCallbacks() {
        require(msg.sender == storageT.callbacks(), "CALLBACKS_ONLY");
        _;
    }

    // Manage params
    function updateTriggerTimeout(uint _triggerTimeout) external onlyGov {
        require(_triggerTimeout >= 5, "LESS_THAN_5");

        triggerTimeout = _triggerTimeout;
        emit NumberUpdated("triggerTimeout", _triggerTimeout);
    }

    // Triggers
    function storeFirstToTrigger(TriggeredLimitId calldata _id, address _bot) external override onlyTrading {
        TriggeredLimit storage t = triggeredLimits[_id.trader][_id.pairIndex][_id.index][_id.order];

        t.first = _bot;
        t.block = block.number;

        emit TriggeredFirst(_id, _bot);
    }

    function unregisterTrigger(TriggeredLimitId calldata _id) external override onlyCallbacks {
        delete triggeredLimits[_id.trader][_id.pairIndex][_id.index][_id.order];
        emit TriggerUnregistered(_id);
    }

    // Distribute rewards
    function distributeReward(TriggeredLimitId calldata _id, uint _reward) external override onlyCallbacks {
        TriggeredLimit memory t = triggeredLimits[_id.trader][_id.pairIndex][_id.index][_id.order];

        require(t.block > 0, "NOT_TRIGGERED");

        tokensToClaim[t.first] += _reward;
        emit TriggerRewarded(_id, _reward);
    }

    function claimTokens() external {
        uint tokens = tokensToClaim[msg.sender];
        require(tokens > 0, "NOTHING_TO_CLAIM");

        tokensToClaim[msg.sender] = 0;
        // storageT.handleTokens(msg.sender, tokens, true);
        ICallbacks(storageT.callbacks()).transferFromVault(msg.sender, tokens);

        tokensClaimed[msg.sender] += tokens;
        tokensClaimedTotal += tokens;

        emit TokensClaimed(msg.sender, tokens);
    }

    // Manage open limit order types
    function setOpenLimitOrderType(
        address _trader,
        uint _pairIndex,
        uint _index,
        OpenLimitOrderType _type
    ) external override onlyTrading {
        openLimitOrderTypes[_trader][_pairIndex][_index] = _type;
    }

    // Getters
    function triggered(TriggeredLimitId calldata _id) external view override returns (bool) {
        uint blockNumber = triggeredLimits[_id.trader][_id.pairIndex][_id.index][_id.order].block;
        return blockNumber > 0;
    }

    function timedOut(TriggeredLimitId calldata _id) external view override returns (bool) {
        uint blockNumber = triggeredLimits[_id.trader][_id.pairIndex][_id.index][_id.order].block;
        return blockNumber > 0 && block.number - blockNumber >= triggerTimeout;
    }
}
