// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

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

    function _depositCollateral() private {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
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

    function testCanMintDscAndGetAccountInfo() public {
        _depositCollateral();

        uint256 amountDscToMint = 2e18;
        vm.prank(USER);
        engine.mintDsc(amountDscToMint);

        _checkExpectedDscMintedAndCollateralDeposited(amountDscToMint);
    }

    function testRevertIfHealFactorIsBrokenNoDeposit() public {
        uint256 amountDscToMint = 2e18;
        (, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        vm.prank(USER);
        uint256 healthFactor = engine.calculateHealthFactor(amountDscToMint, collateralValueInUsd);
        vm.expectRevert(
            abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, healthFactor)
        );
        engine.mintDsc(amountDscToMint);
    }

    function testRevertIfHealFactorIsBrokenInMintingDscBelowTwoHundredPercentOvercollateralization() public {
        _depositCollateral();
        (, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
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
        // 2e18 is way below the 10e18 amount collateral
        // which passes the 200% overcollateralization
        uint256 amountDscToMint = 2e18;
        vm.prank(USER);
        engine.mintDsc(amountDscToMint);
        (uint256 totalDscMinted,) = engine.getAccountInformation(USER);
        uint256 dscBalance = dsc.balanceOf(USER);

        assertEq(dscBalance, totalDscMinted);
    }
}


// - Function "depositCollateralAndMintDsc" (location: source ID 29, line 134, chars 4787-5056, hits: 0)
// - Line (location: source ID 29, line 139, chars 4956-5015, hits: 0)
// - Statement (location: source ID 29, line 139, chars 4956-5015, hits: 0)
// - Line (location: source ID 29, line 140, chars 5025-5049, hits: 0)
// - Statement (location: source ID 29, line 140, chars 5025-5049, hits: 0)
// - Branch (branch: 0, path: 0) (location: source ID 29, line 160, chars 5790-5863, hits: 0)
// - Line (location: source ID 29, line 161, chars 5818-5852, hits: 0)
// - Statement (location: source ID 29, line 161, chars 5818-5852, hits: 0)
// - Function "redeemCollateralForDsc" (location: source ID 29, line 171, chars 6175-6495, hits: 0)
// - Line (location: source ID 29, line 176, chars 6339-6363, hits: 0)
// - Statement (location: source ID 29, line 176, chars 6339-6363, hits: 0)
// - Line (location: source ID 29, line 177, chars 6373-6431, hits: 0)
// - Statement (location: source ID 29, line 177, chars 6373-6431, hits: 0)
// - Function "redeemCollateral" (location: source ID 29, line 185, chars 6677-7011, hits: 0)
// - Line (location: source ID 29, line 193, chars 6872-6955, hits: 0)
// - Statement (location: source ID 29, line 193, chars 6872-6955, hits: 0)
// - Line (location: source ID 29, line 194, chars 6965-7004, hits: 0)
// - Statement (location: source ID 29, line 194, chars 6965-7004, hits: 0)
// - Branch (branch: 1, path: 0) (location: source ID 29, line 207, chars 7538-7606, hits: 0)
// - Line (location: source ID 29, line 208, chars 7565-7595, hits: 0)
// - Statement (location: source ID 29, line 208, chars 7565-7595, hits: 0)
// - Function "burnDsc" (location: source ID 29, line 213, chars 7675-7892, hits: 0)
// - Line (location: source ID 29, line 214, chars 7759-7799, hits: 0)
// - Statement (location: source ID 29, line 214, chars 7759-7799, hits: 0)
// - Line (location: source ID 29, line 215, chars 7809-7848, hits: 0)
// - Statement (location: source ID 29, line 215, chars 7809-7848, hits: 0)
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
// - Function "_burnDsc" (location: source ID 29, line 289, chars 10913-11263, hits: 0)
// - Line (location: source ID 29, line 290, chars 11011-11053, hits: 0)
// - Statement (location: source ID 29, line 290, chars 11011-11053, hits: 0)
// - Line (location: source ID 29, line 291, chars 11063-11137, hits: 0)
// - Statement (location: source ID 29, line 291, chars 11063-11137, hits: 0)
// - Statement (location: source ID 29, line 291, chars 11078-11137, hits: 0)
// - Line (location: source ID 29, line 292, chars 11151-11159, hits: 0)
// - Statement (location: source ID 29, line 292, chars 11151-11159, hits: 0)
// - Branch (branch: 4, path: 0) (location: source ID 29, line 292, chars 11147-11220, hits: 0)
// - Branch (branch: 4, path: 1) (location: source ID 29, line 292, chars 11147-11220, hits: 0)
// - Line (location: source ID 29, line 293, chars 11175-11209, hits: 0)
// - Statement (location: source ID 29, line 293, chars 11175-11209, hits: 0)
// - Line (location: source ID 29, line 295, chars 11229-11256, hits: 0)
// - Statement (location: source ID 29, line 295, chars 11229-11256, hits: 0)
// - Function "_redeemCollateral" (location: source ID 29, line 298, chars 11269-11808, hits: 0)
// - Line (location: source ID 29, line 304, chars 11436-11507, hits: 0)
// - Statement (location: source ID 29, line 304, chars 11436-11507, hits: 0)
// - Line (location: source ID 29, line 305, chars 11517-11592, hits: 0)
// - Statement (location: source ID 29, line 305, chars 11517-11592, hits: 0)
// - Line (location: source ID 29, line 307, chars 11643-11719, hits: 0)
// - Statement (location: source ID 29, line 307, chars 11643-11719, hits: 0)
// - Statement (location: source ID 29, line 307, chars 11658-11719, hits: 0)
// - Line (location: source ID 29, line 308, chars 11733-11741, hits: 0)
// - Statement (location: source ID 29, line 308, chars 11733-11741, hits: 0)
// - Branch (branch: 5, path: 0) (location: source ID 29, line 308, chars 11729-11802, hits: 0)
// - Branch (branch: 5, path: 1) (location: source ID 29, line 308, chars 11729-11802, hits: 0)
// - Line (location: source ID 29, line 309, chars 11757-11791, hits: 0)
// - Statement (location: source ID 29, line 309, chars 11757-11791, hits: 0)
// - Branch (branch: 6, path: 0) (location: source ID 29, line 337, chars 12794-12848, hits: 0)
// - Statement (location: source ID 29, line 337, chars 12821-12845, hits: 0)
// - Function "getAccountCollateralValue" (location: source ID 29, line 377, chars 14437-14989, hits: 0)
// - Line (location: source ID 29, line 385, chars 14950-14982, hits: 0)
// - Statement (location: source ID 29, line 385, chars 14950-14982, hits: 0)
// - Function "getHealthFactor" (location: source ID 29, line 400, chars 15613-15727, hits: 0)
// - Line (location: source ID 29, line 401, chars 15694-15720, hits: 0)
// - Statement (location: source ID 29, line 401, chars 15694-15720, hits: 0)
// - Statement (location: source ID 29, line 401, chars 15701-15720, hits: 0)