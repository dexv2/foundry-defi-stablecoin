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
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_WETH_BALANCE = 10 ether;

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

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedAmountDeposited = engine.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(expectedAmountDeposited, AMOUNT_COLLATERAL);
    }
}
