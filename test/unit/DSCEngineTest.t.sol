// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";
import {MockFailedTransfer} from "../mocks/MockFailedTransfer.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DSCEngine engine;
    HelperConfig config;
    DecentralizedStableCoin dsc;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    address public USER = makeAddr("user");
    address public BAD_USER = makeAddr("badUser");
    uint256 public constant AMOUNT_COLLATERAL = 10e18;
    uint256 public constant STARTING_WETH_BALANCE = 10e18;
    uint256 public constant SAFE_DSC_AMOUNT_TO_MINT = 1000e18; // (10e18 * $2000) / 1000e18 = 2 --> 2000% overcollateralize
    int256 public constant ETH_ORIGINAL_PRICE = 2000e8;
    int256 public constant ETH_DUMPED_PRICE = 1000e8;
    uint256 public constant DSC_TO_MINT_OR_MINTED_BY_BAD_USER = 100e18;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_WETH_BALANCE);
        ERC20Mock(weth).mint(BAD_USER, STARTING_WETH_BALANCE);
    }

    ////////////////////////////
    // Constructor Tests      //
    ////////////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    //////////////////////
    // Price Tests      //
    //////////////////////

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        // 15e18 * $2000/ETH = 30,000e18;
        uint256 expectedEthUsd = 30000e18;
        uint256 actualEthUsd = engine.getUsdValue(weth, ethAmount);

        uint256 btcAmount = 15e18;
        // 15e18 * $1000/BTC = 15,000e18;
        uint256 expectedBtcUsd = 15000e18;
        uint256 actualBtcUsd = engine.getUsdValue(wbtc, btcAmount);

        assertEq(expectedEthUsd, actualEthUsd);
        assertEq(expectedBtcUsd, actualBtcUsd);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdEthAmount = 100e18;
        // 100e18 / $2000/ETH = 0.05e18 or 5e16;
        uint256 expectedEthAmount = 5e16;
        uint256 actualEthAmount = engine.getTokenAmountFromUsd(weth, usdEthAmount);

        uint256 usdBtcAmount = 100e18;
        // 100e18 / $1000/BTC = 0.1e18 or 1e17;
        uint256 expectedBtcAmount = 1e17;
        uint256 actualBtcAmount = engine.getTokenAmountFromUsd(wbtc, usdBtcAmount);

        assertEq(expectedEthAmount, actualEthAmount);
        assertEq(expectedBtcAmount, actualBtcAmount);
    }

    //////////////////////////////////
    // depositCollateral Tests      //
    //////////////////////////////////

    function testRevertsIfCollateralZero() public {
        uint256 collateralToDeposit = 0;
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.depositCollateral(weth, collateralToDeposit);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        engine.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function _approveWethToDSCEngine() private {
        vm.prank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
    }

    function _approveDscToDSCEngine() private {
        vm.prank(USER);
        dsc.approve(address(engine), SAFE_DSC_AMOUNT_TO_MINT);
    }

    function _depositCollateral() private {
        _approveWethToDSCEngine();
        vm.prank(USER);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
    }

    function _checkExpectedDscMintedAndCollateralDeposited(uint256 expectedTotalDscMinted) private {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        uint256 expectedAmountCollateralDeposited = engine.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(expectedAmountCollateralDeposited, AMOUNT_COLLATERAL);
    }

    function testCanDepositCollateralAndGetAccountInfo() public {
        _depositCollateral();
        uint256 expectedTotalDscMinted = 0;
        _checkExpectedDscMintedAndCollateralDeposited(expectedTotalDscMinted);
    }

    function testAmountCollateralIsTransferedToDSCEngine() public {
        uint256 startingEthBalance = ERC20Mock(weth).balanceOf(address(engine));
        _depositCollateral();
        uint256 endingEthBalance = ERC20Mock(weth).balanceOf(address(engine));
        assertEq(endingEthBalance, startingEthBalance + AMOUNT_COLLATERAL);
    }

    function testRevertsDepositWithTransferFailed() public {
        vm.startPrank(USER);
        MockFailedTransferFrom mockDsc = new MockFailedTransferFrom();
        tokenAddresses = [address(mockDsc)];
        priceFeedAddresses = [ethUsdPriceFeed];
        DSCEngine mockEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.mint(USER, AMOUNT_COLLATERAL);
        mockDsc.transferOwnership(address(mockEngine));
    
        mockDsc.approve(address(mockEngine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockEngine.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    ////////////////////////
    // mintDsc Tests      //
    ////////////////////////

    function testCanMintDscAndGetAccountInfo() public {
        _depositCollateral();

        uint256 amountDscToMint = 2e18;
        vm.prank(USER);
        engine.mintDsc(amountDscToMint);

        _checkExpectedDscMintedAndCollateralDeposited(amountDscToMint);
    }

    function testRevertIfHealFactorIsBrokenNoDeposit() public {
        uint256 amountDscToMint = 2e18;
        uint256 collateralValueInUsd = engine.getAccountCollateralValue(USER);
        vm.prank(USER);
        uint256 healthFactor = engine.calculateHealthFactor(amountDscToMint, collateralValueInUsd);
        vm.expectRevert(
            abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, healthFactor)
        );
        engine.mintDsc(amountDscToMint);
    }

    function testRevertIfHealFactorIsBrokenInMintingDscBelowTwoHundredPercentOvercollateralization() public {
        _depositCollateral();
        uint256 collateralValueInUsd = engine.getAccountCollateralValue(USER);
        vm.startPrank(USER);
        // We are about to mint DSC with the same amount as collateral value
        // which is below the 200% overcollateralization
        uint256 amountDscToMint = collateralValueInUsd;
        uint256 healthFactor = engine.calculateHealthFactor(amountDscToMint, collateralValueInUsd);
        vm.expectRevert(
            abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, healthFactor)
        );
        engine.mintDsc(amountDscToMint);
        vm.stopPrank();
    }

    function testDscBalanceMintedEqualsAccountInformationDscMinted() public {
        _depositCollateral();
        // (10e18 * $2000) / 10000e18 = 2 --> 200% overcollateralize
        uint256 amountDscToMint = 10000e18;
        vm.prank(USER);
        engine.mintDsc(amountDscToMint);
        (uint256 totalDscMinted,) = engine.getAccountInformation(USER);
        uint256 dscBalance = dsc.balanceOf(USER);

        assertEq(dscBalance, totalDscMinted);
    }

    ////////////////////////////////////////////
    // depositCollateralAndMintDsc Tests      //
    ////////////////////////////////////////////

    modifier depositAndMint() {
        _approveWethToDSCEngine();
        vm.prank(USER);
        engine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, SAFE_DSC_AMOUNT_TO_MINT);
        _;
    }

    function testCanDepositCollateralAndMintDscInASingleTransaction() public depositAndMint {
        _checkExpectedDscMintedAndCollateralDeposited(SAFE_DSC_AMOUNT_TO_MINT);
    }

    /////////////////////////////////
    // redeemCollateral Tests      //
    /////////////////////////////////

    function testCanRedeemCollateralAndUpdateAccountCollateralValue() public depositAndMint {
        uint256 maxEthAmountCanBeRedeemed = 9e18; // 9 ETH
        vm.prank(USER);
        // health factor will be exactly 1e18
        // collateral value in USD will be 200% the minted DSC (SAFE_DSC_AMOUNT_TO_MINT)
        // $1000 * 2 = $2000
        engine.redeemCollateral(weth, maxEthAmountCanBeRedeemed);

        uint256 expectedCollateralValueInUsd = 2000e18; // $2000
        uint256 actualCollateralValueInUsd = engine.getAccountCollateralValue(USER);

        assertEq(expectedCollateralValueInUsd, actualCollateralValueInUsd);
    }

    function testRevertIfUserRedeemsAndBreaksHealthFactor() public depositAndMint {
        uint256 ethAmountToRedeem = 91e17; // 9.1 ETH, exceeds max eth that can be redeemed
        // health factor will be below 1e18
        // collateral value in USD will be less than 200% the minted DSC (SAFE_DSC_AMOUNT_TO_MINT)
        uint256 collateralValueInEthAfterTransaction = AMOUNT_COLLATERAL - ethAmountToRedeem;
        uint256 collateralValueInUsdAfterTransaction = engine.getUsdValue(weth, collateralValueInEthAfterTransaction);
        uint256 healthFactor = engine.calculateHealthFactor(SAFE_DSC_AMOUNT_TO_MINT, collateralValueInUsdAfterTransaction);
        vm.expectRevert(
            abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, healthFactor)
        );
        vm.prank(USER);
        engine.redeemCollateral(weth, ethAmountToRedeem);
    }

    ////////////////////////
    // burnDsc Tests      //
    ////////////////////////

    function testCanBurnDscAndUpdateAccountDscMinted() public depositAndMint {
        uint256 oneFourthOfMintedDscToBurn = SAFE_DSC_AMOUNT_TO_MINT / 4;
        uint256 amountDscAfter = SAFE_DSC_AMOUNT_TO_MINT - oneFourthOfMintedDscToBurn;
        _approveDscToDSCEngine();
        vm.prank(USER);
        engine.burnDsc(oneFourthOfMintedDscToBurn);

        (uint256 totalDscMinted,) = engine.getAccountInformation(USER);

        assertEq(totalDscMinted, amountDscAfter);
    }

    function testRevertsIfBurnAmountIsZero() public depositAndMint {
        vm.prank(USER);
        vm.expectRevert();
        engine.burnDsc(0);
    }

    function testCantBurnMoreThanUserHave() public depositAndMint {
        _approveDscToDSCEngine();
        vm.startPrank(USER);
        vm.expectRevert();
        engine.burnDsc(SAFE_DSC_AMOUNT_TO_MINT + 1);
        vm.stopPrank();
    }

    ///////////////////////////////////////
    // redeemCollateralForDsc Tests      //
    ///////////////////////////////////////

    // this test needs it's own setup
    function testRevertsIfTransferFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransfer mockDsc = new MockFailedTransfer();
        tokenAddresses = [address(mockDsc)];
        priceFeedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(mockDsc)
        );
        mockDsc.mint(USER, AMOUNT_COLLATERAL);

        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(address(mockDsc)).approve(address(mockDsce), AMOUNT_COLLATERAL);
        // Act / Assert
        mockDsce.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDsce.redeemCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCanRedeemCollateralAndBurnDscInOneTransaction() public depositAndMint {
        _approveDscToDSCEngine();
        vm.prank(USER);
        engine.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, SAFE_DSC_AMOUNT_TO_MINT);

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);

        assertEq(totalDscMinted, 0);
        assertEq(collateralValueInUsd, 0);
    }

    ////////////////////////////////
    // getHealthFactor Tests      //
    ////////////////////////////////

    function testCanReturnAccurateHealthFactor() public depositAndMint {
        // collateralValueInUsd: 10 * $2000 ETH = $20000 ETH
        // totalDscMinted: $1000 DSC
        // collateralAdjustedForThreshold = $20000 ETH * 50 / 100 = $10000
        // healthFactor: $10000 / $1000 = 10
        uint256 healthFactor = engine.getHealthFactor(USER);
        uint256 expectedHealthFactor = 10e18;

        assertEq(healthFactor, expectedHealthFactor);
    }

    //////////////////////////
    // liquidate Tests      //
    //////////////////////////

    modifier depositAndMintByBadUser() {
        // initial ETH value: $2000 / ETH 
        // initial collateral value: $280 ETH
        // minted dsc: $100 DSC
        // more than 200% overcollateral
        vm.startPrank(BAD_USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        uint256 collateralToDepositInUsd = 280e18;
        uint256 collateralToDepositInEth = engine.getTokenAmountFromUsd(weth, collateralToDepositInUsd);
        engine.depositCollateralAndMintDsc(weth, collateralToDepositInEth, DSC_TO_MINT_OR_MINTED_BY_BAD_USER);
        vm.stopPrank();
        _;
    }

    function testCanLiquidateUserWithBadHealthFactor() public depositAndMint depositAndMintByBadUser {
        // ETH got dumped to value: $1000 / ETH
        // updated collateral value would be: $140 ETH
        // minted dsc: $100 DSC
        // less than 200% overcollateral
        // USER can liquidate BAD_USER
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ETH_DUMPED_PRICE);
        uint256 startingUserEthBalanceInUsd = engine.getUsdValue(weth, ERC20Mock(weth).balanceOf(USER));
        uint256 startingUserDscBalance = dsc.balanceOf(USER);
        (uint256 startingBadUserDscMinted, uint256 startingBadUserCollateralValueInUsd) = engine.getAccountInformation(BAD_USER);
        vm.startPrank(USER);
        dsc.approve(address(engine), DSC_TO_MINT_OR_MINTED_BY_BAD_USER);
        engine.liquidate(weth, BAD_USER, DSC_TO_MINT_OR_MINTED_BY_BAD_USER);
        vm.stopPrank();
        uint256 endingUserEthBalanceInUsd = engine.getUsdValue(weth, ERC20Mock(weth).balanceOf(USER));
        uint256 endingUserDscBalance = dsc.balanceOf(USER);
        (uint256 endingBadUserDscMinted, uint256 endingBadUserCollateralValueInUsd) = engine.getAccountInformation(BAD_USER);

        // USER is rewarded 10% bonus
        // The USER should get $110 ETH after covering $100 DSC on behalf of BAD_USER
        // The USER should have $110 worth of ETH BALANCE 
        uint256 userCollateralAmountGain = 110e18;
        uint256 userDscCovered = DSC_TO_MINT_OR_MINTED_BY_BAD_USER;

        assertEq(endingUserEthBalanceInUsd, startingUserEthBalanceInUsd + userCollateralAmountGain);
        assertEq(endingUserDscBalance, startingUserDscBalance - userDscCovered);
        assertEq(endingBadUserDscMinted, startingBadUserDscMinted - DSC_TO_MINT_OR_MINTED_BY_BAD_USER);
        assertEq(endingBadUserCollateralValueInUsd, startingBadUserCollateralValueInUsd - userCollateralAmountGain);

        // Return ETH value to original
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ETH_ORIGINAL_PRICE);
    }

    function testRevertsIfUserLiquidatesAnotherUserWithGoodHealthFactor() public depositAndMint depositAndMintByBadUser {
        // Bad user has $280 ETH and minted $100 DSC
        // Has more than 200% overcollateral
        // Has good health factor
        vm.startPrank(USER);
        dsc.approve(address(engine), DSC_TO_MINT_OR_MINTED_BY_BAD_USER);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        engine.liquidate(weth, BAD_USER, DSC_TO_MINT_OR_MINTED_BY_BAD_USER);
        vm.stopPrank();
    }

    function testRevertsIfHealthFactorNotImprovedAfterLiquidation() public depositAndMint depositAndMintByBadUser {
        // ETH got dumped to value: $18 / ETH
        // updated collateral value would be: $2.52 ETH
        // minted dsc: $100 DSC
        // way way undercollateral!!
        // USER can liquidate BAD_USER
        int256 ethUsdUpdatedPrice = 18e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        // User is already undercollateralize, it's too late to liquidate
        // Liquidating will make user's health factor worse
        uint256 amountDscToCover = 1e18;
        vm.startPrank(USER);
        dsc.approve(address(engine), amountDscToCover);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        engine.liquidate(weth, BAD_USER, amountDscToCover);
        vm.stopPrank();

        // Return ETH value to original
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ETH_ORIGINAL_PRICE);
    }
}
