// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";

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
    uint256 public constant AMOUNT_COLLATERAL = 10e18;
    uint256 public constant STARTING_WETH_BALANCE = 10e18;
    uint256 public constant SAFE_DSC_AMOUNT_TO_MINT = 1000e18; // (10e18 * $2000) / 1000e18 = 2 --> 2000% overcollateralize

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_WETH_BALANCE);
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
}


// - Function "redeemCollateralForDsc" (location: source ID 29, line 171, chars 6175-6495, hits: 0)
// - Line (location: source ID 29, line 176, chars 6339-6363, hits: 0)
// - Statement (location: source ID 29, line 176, chars 6339-6363, hits: 0)
// - Line (location: source ID 29, line 177, chars 6373-6431, hits: 0)
// - Statement (location: source ID 29, line 177, chars 6373-6431, hits: 0)
// - Branch (branch: 1, path: 0) (location: source ID 29, line 207, chars 7538-7606, hits: 0)
// - Line (location: source ID 29, line 208, chars 7565-7595, hits: 0)
// - Statement (location: source ID 29, line 208, chars 7565-7595, hits: 0)
// - Function "liquidate" (location: source ID 29, line 240, chars 8993-10632, hits: 0)
// - Line (location: source ID 29, line 250, chars 9222-9276, hits: 0)
// - Statement (location: source ID 29, line 250, chars 9222-9276, hits: 0)
// - Statement (location: source ID 29, line 250, chars 9257-9276, hits: 0)
// - Line (location: source ID 29, line 251, chars 9290-9335, hits: 0)
// - Statement (location: source ID 29, line 251, chars 9290-9335, hits: 0)
// - Branch (branch: 2, path: 0) (location: source ID 29, line 251, chars 9286-9396, hits: 0)
// - Branch (branch: 2, path: 1) (location: source ID 29, line 251, chars 9286-9396, hits: 0)
// - Line (location: source ID 29, line 252, chars 9351-9385, hits: 0)
// - Statement (location: source ID 29, line 252, chars 9351-9385, hits: 0)
// - Line (location: source ID 29, line 260, chars 9609-9692, hits: 0)
// - Statement (location: source ID 29, line 260, chars 9609-9692, hits: 0)
// - Statement (location: source ID 29, line 260, chars 9646-9692, hits: 0)
// - Line (location: source ID 29, line 268, chars 10032-10130, hits: 0)
// - Statement (location: source ID 29, line 268, chars 10032-10130, hits: 0)
// - Statement (location: source ID 29, line 268, chars 10058-10130, hits: 0)
// - Line (location: source ID 29, line 269, chars 10140-10218, hits: 0)
// - Statement (location: source ID 29, line 269, chars 10140-10218, hits: 0)
// - Statement (location: source ID 29, line 269, chars 10174-10218, hits: 0)
// - Line (location: source ID 29, line 270, chars 10228-10300, hits: 0)
// - Statement (location: source ID 29, line 270, chars 10228-10300, hits: 0)
// - Line (location: source ID 29, line 272, chars 10341-10380, hits: 0)
// - Statement (location: source ID 29, line 272, chars 10341-10380, hits: 0)
// - Line (location: source ID 29, line 274, chars 10391-10443, hits: 0)
// - Statement (location: source ID 29, line 274, chars 10391-10443, hits: 0)
// - Statement (location: source ID 29, line 274, chars 10424-10443, hits: 0)
// - Line (location: source ID 29, line 275, chars 10457-10507, hits: 0)
// - Statement (location: source ID 29, line 275, chars 10457-10507, hits: 0)
// - Branch (branch: 3, path: 0) (location: source ID 29, line 275, chars 10453-10577, hits: 0)
// - Branch (branch: 3, path: 1) (location: source ID 29, line 275, chars 10453-10577, hits: 0)
// - Line (location: source ID 29, line 276, chars 10523-10566, hits: 0)
// - Statement (location: source ID 29, line 276, chars 10523-10566, hits: 0)
// - Line (location: source ID 29, line 278, chars 10586-10625, hits: 0)
// - Statement (location: source ID 29, line 278, chars 10586-10625, hits: 0)
// - Branch (branch: 4, path: 0) (location: source ID 29, line 292, chars 11147-11220, hits: 0)
// - Line (location: source ID 29, line 293, chars 11175-11209, hits: 0)
// - Statement (location: source ID 29, line 293, chars 11175-11209, hits: 0)
// - Branch (branch: 5, path: 0) (location: source ID 29, line 308, chars 11729-11802, hits: 0)
// - Line (location: source ID 29, line 309, chars 11757-11791, hits: 0)
// - Statement (location: source ID 29, line 309, chars 11757-11791, hits: 0)
// - Branch (branch: 6, path: 0) (location: source ID 29, line 337, chars 12794-12848, hits: 0)
// - Statement (location: source ID 29, line 337, chars 12821-12845, hits: 0)
// - Line (location: source ID 29, line 385, chars 14950-14982, hits: 0)
// - Statement (location: source ID 29, line 385, chars 14950-14982, hits: 0)
// - Function "getHealthFactor" (location: source ID 29, line 400, chars 15613-15727, hits: 0)
// - Line (location: source ID 29, line 401, chars 15694-15720, hits: 0)
// - Statement (location: source ID 29, line 401, chars 15694-15720, hits: 0)
// - Statement (location: source ID 29, line 401, chars 15701-15720, hits: 0)