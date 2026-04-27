// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {NegRiskAdapter_SetUp} from "src/test/NegRiskAdapter/NegRiskAdapterSetUp.sol";
import {NegRiskIdLib} from "src/libraries/NegRiskIdLib.sol";

contract NegRiskAdapter_ConvertYESPositions_Test is NegRiskAdapter_SetUp {
    uint256 constant QUESTION_COUNT_MAX = 32;
    bytes32 marketId;

    /// @notice `_indexSet` bit 1 = Brian holds YES and burns it; bit 0 = Brian receives NO (adapter splits).
    function _beforeYES(uint256 _questionCount, uint256 _feeBips, uint256 _indexSet, uint256 _amount) internal {
        bytes memory data = new bytes(0);

        vm.prank(oracle);
        marketId = nrAdapter.prepareMarket(_feeBips, data);

        uint8 i = 0;
        while (i < _questionCount) {
            vm.prank(oracle);
            bytes32 questionId = nrAdapter.prepareQuestion(marketId, data);
            bytes32 conditionId = nrAdapter.getConditionId(questionId);

            vm.startPrank(alice);
            usdc.mint(alice, _amount);
            usdc.approve(address(nrAdapter), _amount);
            nrAdapter.splitPosition(conditionId, _amount);
            vm.stopPrank();

            ++i;
        }

        assertEq(nrAdapter.getQuestionCount(marketId), _questionCount);

        i = 0;
        while (i < _questionCount) {
            if (_indexSet & (1 << i) > 0) {
                uint256 yesPositionId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, i), true);
                vm.prank(alice);
                ctf.safeTransferFrom(alice, brian, yesPositionId, _amount, "");
                assertEq(ctf.balanceOf(brian, yesPositionId), _amount);
            }
            ++i;
        }
    }

    function _afterYES(uint256 _questionCount, uint256 _feeBips, uint256 _indexSet, uint256 _amount) internal view {
        uint256 feeAmount = (_amount * _feeBips) / FEE_BIPS_MAX;
        uint256 amountOut = _amount - feeAmount;

        uint256 userYesBurnQuestionCount;
        uint256 complementQuestionCount;

        uint8 i = 0;
        while (i < _questionCount) {
            if (_indexSet & (1 << i) > 0) {
                uint256 yesPositionId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, i), true);
                uint256 noPositionId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, i), false);

                assertEq(ctf.balanceOf(brian, yesPositionId), 0);
                assertEq(ctf.balanceOf(nrAdapter.NO_TOKEN_BURN_ADDRESS(), yesPositionId), _amount);
                assertEq(ctf.balanceOf(address(nrAdapter), yesPositionId), 0);
                assertEq(ctf.balanceOf(address(nrAdapter), noPositionId), 0);
                ++userYesBurnQuestionCount;
            } else {
                uint256 yesPositionId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, i), true);
                uint256 noPositionId = nrAdapter.getPositionId(NegRiskIdLib.getQuestionId(marketId, i), false);

                assertEq(ctf.balanceOf(brian, noPositionId), amountOut);
                assertEq(ctf.balanceOf(vault, noPositionId), feeAmount);
                assertEq(ctf.balanceOf(nrAdapter.NO_TOKEN_BURN_ADDRESS(), yesPositionId), _amount);
                assertEq(ctf.balanceOf(address(nrAdapter), yesPositionId), 0);
                assertEq(ctf.balanceOf(address(nrAdapter), noPositionId), 0);
                ++complementQuestionCount;
            }
            ++i;
        }

        assertEq(userYesBurnQuestionCount + complementQuestionCount, _questionCount);

        // Alice splits lock `_amount` WCOL per question in CTF; partial convertYES adds another `_amount` per complement split.
        uint256 expectedWcolInCtf = _amount * (_questionCount + complementQuestionCount);
        assertEq(wcol.balanceOf(address(ctf)), expectedWcolInCtf);

        if (userYesBurnQuestionCount == _questionCount) {
            assertEq(usdc.balanceOf(brian), amountOut);
        } else {
            assertEq(usdc.balanceOf(brian), 0);
        }
    }

    function test_convertYESPositions_partialIndices(
        uint256 _questionCount,
        uint256 _feeBips,
        uint256 _indexSet,
        uint128 _amount
    ) public {
        vm.assume(_amount > 0);

        _feeBips = bound(_feeBips, 0, FEE_BIPS_MAX);
        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);
        _indexSet = bound(_indexSet, 1, (2 ** _questionCount) - 2);

        _beforeYES(_questionCount, _feeBips, _indexSet, _amount);

        uint256 userYesBurnQuestionCount;
        uint256 j = 0;
        while (j < _questionCount) {
            if (_indexSet & (1 << j) > 0) {
                ++userYesBurnQuestionCount;
            }
            ++j;
        }

        vm.startPrank(brian);
        // Partial conversion pulls (noPositionCount - 1) * _amount USDC, i.e. (complementQuestionCount - 1) * _amount.
        if (userYesBurnQuestionCount < _questionCount) {
            uint256 payMultiplier = _questionCount - userYesBurnQuestionCount - 1;
            if (payMultiplier > 0) {
                usdc.mint(brian, payMultiplier * _amount);
                usdc.approve(address(nrAdapter), payMultiplier * _amount);
            }
        }
        ctf.setApprovalForAll(address(nrAdapter), true);

        vm.expectEmit();
        emit PositionsConverted(brian, marketId, _indexSet, _amount);
        nrAdapter.convertYESPositions(marketId, _indexSet, _amount);
        vm.stopPrank();

        _afterYES(_questionCount, _feeBips, _indexSet, _amount);
    }

    function test_convertYESPositions_allIndices(uint256 _questionCount, uint256 _feeBips, uint128 _amount) public {
        vm.assume(_amount > 0);

        _feeBips = bound(_feeBips, 0, FEE_BIPS_MAX);
        _questionCount = bound(_questionCount, 2, QUESTION_COUNT_MAX);
        uint256 _indexSet = (2 ** _questionCount) - 1;

        _beforeYES(_questionCount, _feeBips, _indexSet, _amount);

        vm.startPrank(brian);
        ctf.setApprovalForAll(address(nrAdapter), true);

        vm.expectEmit();
        emit PositionsConverted(brian, marketId, _indexSet, _amount);
        nrAdapter.convertYESPositions(marketId, _indexSet, _amount);
        vm.stopPrank();

        _afterYES(_questionCount, _feeBips, _indexSet, _amount);
    }

    function test_convertYESPositions_zeroAmount(uint256 _a, uint256 _b) public {
        uint256 amount = 0;
        uint256 questionCountMax = 32;
        uint256 questionCount = bound(_a, 2, questionCountMax);
        uint256 indexSet = bound(_b, 1, (2 ** questionCount) - 1);

        _beforeYES(questionCount, 0, indexSet, amount);

        vm.prank(brian);
        nrAdapter.convertYESPositions(marketId, indexSet, amount);
    }

    function test_revert_convertYESPositions_marketNotPrepared(bytes32 _marketId) public {
        vm.expectRevert(MarketNotPrepared.selector);
        nrAdapter.convertYESPositions(_marketId, 0, 0);
    }

    function test_revert_convertYESPositions_noConvertiblePositions() public {
        vm.prank(oracle);
        marketId = nrAdapter.prepareMarket(0, "");

        vm.expectRevert(NoConvertiblePositions.selector);
        nrAdapter.convertYESPositions(marketId, 0, 0);

        vm.prank(oracle);
        nrAdapter.prepareQuestion(marketId, "");

        vm.expectRevert(NoConvertiblePositions.selector);
        nrAdapter.convertYESPositions(marketId, 0, 0);

        vm.prank(oracle);
        nrAdapter.prepareQuestion(marketId, "");

        vm.expectRevert(InvalidIndexSet.selector);
        nrAdapter.convertYESPositions(marketId, 0, 0);
    }

    function test_revert_convertYESPositions_invalidIndexSet(uint256 _a, uint256 _b, uint256 _c, uint128 _amount)
        public
    {
        vm.assume(_amount > 0);

        uint256 feeBips = 10_000;
        uint256 questionCountMax = 32;
        uint256 questionCount = bound(_a, 2, questionCountMax);
        uint256 indexSet = bound(_b, 1, (2 ** questionCount) - 1);

        _beforeYES(questionCount, feeBips, indexSet, _amount);

        uint256 zeroIndexSet = 0;
        vm.expectRevert(InvalidIndexSet.selector);
        nrAdapter.convertYESPositions(marketId, zeroIndexSet, 0);

        uint256 invalidIndexSet = bound(_c, 2 ** questionCount, type(uint256).max);
        vm.expectRevert(InvalidIndexSet.selector);
        nrAdapter.convertYESPositions(marketId, invalidIndexSet, 0);
    }
}
