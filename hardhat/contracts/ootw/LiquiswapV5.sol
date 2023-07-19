// v5 change aaave deposits to user's address vs this contract's address
// this way we don't need to track the user's deposits and interest, but have to withdraw individual deposit amounts
// v4 add aave supply liquidity 
// v3 version with MATIC
// dropped the WETH version to implement Aave staking which meant we had to switch to depositing MATIC
// for uniswap v3, still using the swap exact input single function
// even though using native token (MATIC), we must supply the WMATIC token address
// guessing that works by wrapping the token behind the scenes for us


// supply matic to aave on deposit
// withdraw matic supplied to aave on liquidation

//do we need to add an operation to recover refund amounts? 
// e.g. possibly tokens in leftover after a swap?

// 1000 wei 0.000000000000001

// testing values

// deposit amounts
// keep test amounts low as testnet aave tends to fail with higher amounts (probably due to liquidity)
// don't test withdrawLiquidity with 1 wei. It seems to always fail when something higher would work. Possibly due to +/- issue
// if withdrawLiquidity tests are failing, try adding more liquidity to the Aave aToken contract so it has enough MATIC to pay out
// guessing that hit problems due to lack of activity on the testnet
// the contract doesn't have funds to cover interest as no funds added, or other users have withdrawn the contracts funds
// e.g.  works for this much of matic -> 100000 wei  2022-11-10 had to drop deposits to 10000 as if more supplied, couldn't withdraw it
//       works for this much of matic in their app -> 0.000099(max amt.)
// liquidations levels
// MATIC: indicative price: 94819478, test liquidation price: 80000000, price drop: 30000000



// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.8.7;
pragma abicoder v2;

// uniswap
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
// chainlink price feeds
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
// chainlink automation
import "@chainlink/contracts/src/v0.8/AutomationCompatible.sol";
// OZ - dupe - IERC20 interface declared below
//import "@openzeppelin/contracts/interfaces/IERC20.sol";
// aave
import {IPoolAddressesProvider} from "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";

// note: ETH just refers to native token. so MATIC here
interface IWETHGateway{
      function depositETH(address pool,address onBehalfOf,uint16 referralCode) external payable;
      function withdrawETH(address pool,uint256 amount,address to) external;
}


interface IERC20{
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
}

contract LiquiSwapV5 is AutomationCompatibleInterface {

    event UserAdded(address indexed user);
    event UserDeleted(address indexed user);
    event Deposit(address indexed user, string token, uint amount);
    event Withdrawal(address indexed user, string token, uint amount);
    event Liquidation(int indexed price, uint targetAmount, uint actualAmount);

    // chainlink price feed
    address MATICvUSD = 0xd0D5e3DB44DE05E9F294BB0a3bEEaF030DE24Ada;  // MATIC/USD - Mumbai
    AggregatorV3Interface internal priceFeed = AggregatorV3Interface(MATICvUSD);

    // uniswap
    address constant routerAddress = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    ISwapRouter internal immutable swapRouter = ISwapRouter(routerAddress);

    address WMATIC = 0x9c3C9283D3e44854697Cd22D3Faa240Cfb032889; //Wrapped MATIC token contract

    address constant DAI = 0x001B3B4d0F3714Ca98ba10F6042DaEbF0B1B7b6F;
    IERC20 internal DAIToken = IERC20(DAI);

    // aave
    // address _addressProvider = 0x5343b5bA672Ae99d627A1C87866b8E53F47Db2E6;    // ---> this isn't used anywhere
    address pool = 0x6C9fB0D5bD9429eb9Cd96B85B81d872281771E6B;

    IWETHGateway immutable WETHGateway = IWETHGateway(0x2a58E9bbb5434FdA7FF78051a4B82cb0EF669C17);
    IERC20 AaveWMatic = IERC20(0x89a6AE840b3F8f489418933A220315eeA36d11fF);  // WMATIC-AToken-Polygon  


    // For this example, we will set the pool fee to 0.3%.
    uint24 constant poolFee = 3000;

    mapping(address => bool) public owners;     // owner address => bool
    uint numOwners;


    /// @dev keeps track of users and their liquidation/stop prices
    /// mapping for lookups, array for iterating
    address[] public usersIndex;
    mapping(address => user) public users;

    struct user {
        uint usersIndexPosition;
        int liquidationPrice;
        uint sharesOfLiquidation;
        uint balanceDAI;
    }


// for testing only
    int public priceDropAmount; // for testing can simulate a big drop in price
    // uint public wtafAmount;
    // uint public wtafBalance;
    // uint public wtafAllowance;
// testing

    /// @dev add dummy first user so it's certain a userIndexPosition test returning 0 means user doesn't exist in mapping and corresponding array
    constructor () {
        owners[msg.sender] = true;
        ++numOwners;
        usersIndex.push(address(0));
    }


    receive() external payable {}
    fallback() external payable {}


    modifier onlyOwners {
        require(owners[msg.sender], "only owners");
        _;
    }


    function addOwner(address _newOwner) external onlyOwners {
        owners[_newOwner] = true;
        ++numOwners;
    }


    function delOwner(address _delOwner) external onlyOwners {
        require(numOwners > 1, "can't del last owner");
        require(owners[_delOwner], "not an owner");
        owners[_delOwner] = false;
        --numOwners;
    }

// ---> get latest price for MATIC/USD - this can be replaced by something else
    /**
     * Returns the latest MATIC/USD price
     */
    function getLatestPrice() public view returns (int) {
        (
            uint80 roundID, 
            int price,
            uint startedAt,
            uint timeStamp,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();
        return price - priceDropAmount;  // priceTestingFactor aid for testing only
    }
// <---

// ---> added add / delete user functions
    // @ todo: secure who can execute function
    //  : public while testing

    function addUser() public {
        require(users[msg.sender].usersIndexPosition == 0, "user already added");

        usersIndex.push(msg.sender);
        users[msg.sender] = user({usersIndexPosition: usersIndex.length, liquidationPrice: -1, sharesOfLiquidation: 0, balanceDAI: 0});
        emit UserAdded(msg.sender);
    }

    
    /// @dev set/change the liquidation price for an existing user
    function setLiquidationPrice(int _liquidationPrice) external {
        require(users[msg.sender].usersIndexPosition != 0, "not a user");
        users[msg.sender].liquidationPrice = _liquidationPrice;
    }


    /// @dev returns the liquidation price for the calling user
    function getLiquidationPrice() external view returns (int) {
        return users[msg.sender].liquidationPrice;
    }


    /// @dev returns the liquidation price for a user
    function getLiquidationPrice(address _addr) external view returns (int) {
        return users[_addr].liquidationPrice;
    }


    //  : public while testing
    function delUser() public {
        require(users[msg.sender].usersIndexPosition != 0, "not a user");
        require(users[msg.sender].balanceDAI == 0, "DAI balance > 0");
        uint _pos = users[msg.sender].usersIndexPosition;
        usersIndex[_pos] = usersIndex[usersIndex.length -1];
        usersIndex.pop();
        delete users[msg.sender];
        emit UserDeleted(msg.sender);
    }


    /// @dev all native token sent is deposited to 
    function supplyLiquidity() public payable {
        if(users[msg.sender].usersIndexPosition == 0) addUser();

        WETHGateway.depositETH{value: msg.value}(pool, msg.sender, 0);

        emit Deposit(msg.sender, "MATIC", msg.value);
    }


    function supplyLiquidity(int _liquidationPrice) external payable {
        supplyLiquidity();
        users[msg.sender].liquidationPrice = _liquidationPrice;
    }
    

    /// @dev balances before and after interacting with aToken contract as actual amounts often not what was expected
    /// can fail if AaveWMATIC contract doesn't have enough MATIC to pay out. Can add more liquidity to try again
    /// don't test with a value of 1 wei, it fails when I higher amount might work. possibly due to +/- issue
    function withdrawLiquidity() external {
        uint _balance = AaveWMatic.balanceOf(msg.sender);
        withdrawLiquidity(_balance);
    }


    function withdrawLiquidity(uint _amount) public {
        require(_amount <= AaveWMatic.balanceOf(msg.sender), "amount > balance");  //new
        require(_amount <= AaveWMatic.allowance(msg.sender, address(this)), "amount > allowance"); //new

        // transfer aTokens from user to contract
        uint _contractBalanceBefore = getContractBalanceAaveWMATIC();   //new
        transferAaveWMATIC(_amount);
        uint _verifiedAmount = getContractBalanceAaveWMATIC() - _contractBalanceBefore; //new

        // send back aTokens and receive native tokens
        _contractBalanceBefore = getContractBalanceMATIC();
        burnAaveWMATIC(_verifiedAmount);
        _verifiedAmount = getContractBalanceMATIC() - _contractBalanceBefore;

        // send native tokens to user 
        (bool success, ) = msg.sender.call{value: _verifiedAmount}("");
        require(success, "withdraw failed");
    }


    // transfer can be used after supplyLiquidityUser() and the user has approved this contract 
    // transfer _amount aTokens from msg.sender to contract
    function transferAaveWMATIC(uint _amount) private {
        AaveWMatic.transferFrom(msg.sender, address(this), _amount);
    }

    
    // transfer msg.sender's balanceOf aTokens to contract
    function transferAaveWMATIC() private {
        uint _balance = AaveWMatic.balanceOf(msg.sender);
        transferAaveWMATIC(_balance);
    }


    // check if contract has an allowance for the user's aTokens
    // the user can choose to have the contract only liquidate the approval amount of their balance
    function isApproved() external view returns (bool) {
        return isApproved(msg.sender);
    }
    
    function isApproved(address _user) public view returns (bool) {
        return getAaveWMATICAllowance(_user) > 0;
    }

    
    // send aTokens back to AaveWMATIC contract to get back MATIC
    function burnAaveWMATIC(uint _amount) private {
        uint256 balance = AaveWMatic.balanceOf(address(this));
        require(_amount <= balance, "amount > balance");

        AaveWMatic.approve(address(WETHGateway), _amount);
        WETHGateway.withdrawETH(pool, _amount, address(this));
    }


    function getBalanceDAI() public view returns (uint) {
        return users[msg.sender].balanceDAI;
    }


    function withdrawDAI() external {
        uint _balance = getBalanceDAI();
        users[msg.sender].balanceDAI = 0;
        DAIToken.transfer(msg.sender, _balance);

        emit Withdrawal(msg.sender, "DAI", _balance);
    }


    function getBalanceAaveWMATIC() public view returns (uint) {
        return AaveWMatic.balanceOf(msg.sender);
    }


    function getBalanceAaveWMaticAddr(address _addr) public view returns (uint) {
        return AaveWMatic.balanceOf(_addr);
    }


    /// @dev returns contract's aWMATIC allowance approved by msg.sender
    function getAaveWMATICAllowance() public view returns (uint) {
         return getAaveWMATICAllowance(msg.sender);
    }


    /// @dev returns contract's aWMATIC allowance approved by _addr
    function getAaveWMATICAllowance(address _addr) public view returns (uint) {
         return AaveWMatic.allowance(_addr, address(this));
    }


    /// @dev returns the contract's aave Token wMatic balance
    function getContractBalanceAaveWMATIC() public view returns(uint) {
        return AaveWMatic.balanceOf(address(this));
    }


    /// @dev returns the contract's native token balance
    function getContractBalanceMATIC() public view returns(uint256){
        return address(this).balance;
    }

    /// @dev returns the contract's DAI token balance
    function getContractBalanceDAI() public view returns(uint256){
        return DAIToken.balanceOf(address(this));
    }


    /// @dev determine which accounts meet the criteria for liquidation
    /// account liquidated if native token price drops below the user's liquidation price
    /// and they have a non zero balance of aave aToken, and they have approved this contract to spend that balance
    /// concatenate the address into a performData to be used by performUpkeep
    function checkUpkeep(bytes calldata checkData) external view override returns (bool upkeepNeeded, bytes memory performData) {
        int _price = getLatestPrice();

        for(uint i = 1; i < usersIndex.length; ++i) {
            address _userAddr = usersIndex[i];
            user memory _user = users[_userAddr];
            if(_price <= _user.liquidationPrice) {
                uint _balance = getBalanceAaveWMaticAddr(_userAddr);
                if( _balance > 0 && isApproved(_userAddr)) {
                    performData = abi.encodePacked(performData, _userAddr);
                }
            }
        }
        if(performData.length > 0) upkeepNeeded = true;
    }


    /// @dev liquidate positions of user addresses passed in performData
    /// the users' aTokens are tranferred to the contract and their share/proportion of total aTokens
    /// is the share/proportion of the total DAI after the aTokens are convertered back to 
    /// native tokens and the native tokens swapped for stable coin (DAI)
    function performUpkeep(bytes calldata performData) external override {
        
        int _price = getLatestPrice();

        uint amountIn;
        address _userAddr;

        // re-check of conditions required
        for(uint _startPos; _startPos < performData.length; _startPos += 20) {
            _userAddr = address(bytes20(performData[_startPos:_startPos + 20]));

            if(_price <= users[_userAddr].liquidationPrice) {
                uint _balance = getBalanceAaveWMaticAddr(_userAddr);
                uint _allowance = getAaveWMATICAllowance(_userAddr);
                if( _balance > 0 && _allowance > 0) {
                    // transfer the balance or allowance amount of user's aTokens to this contract. whichever is smaller
                    uint _transferAmount;
                    if(_balance <= _allowance) {
                        _transferAmount = _balance;
                    } else {
                        _transferAmount = _allowance;
                    }
                    uint _contractBalanceBefore = getContractBalanceAaveWMATIC();
                    AaveWMatic.transferFrom(_userAddr, address(this), _transferAmount);
                    uint _actual = getContractBalanceAaveWMATIC() - _contractBalanceBefore;
                    
                    users[_userAddr].sharesOfLiquidation = _actual;   // the user's share of total
                    amountIn += _actual;    // running total
                }
            }
        }

        if(amountIn > 0) {
            // note the change in the contract's MATIC balance before and after burning user's aTokens
            // burn contract's aTokens for native token (MATIC)
            uint _contractBalanceBefore = getContractBalanceMATIC();
            AaveWMatic.approve(address(WETHGateway), amountIn);
            WETHGateway.withdrawETH(pool, amountIn, address(this));
            uint _actual = getContractBalanceMATIC() - _contractBalanceBefore;

            // swap native token MATIC for DAI
            uint amountOut = Liquidate(_actual);  

            // safe to assume always swaps full amount or nothing?
            if(amountOut > 0) {

                // update the user account balances
                for(uint _startPos; _startPos < performData.length; _startPos += 20) {
                    _userAddr = address(bytes20(performData[_startPos:_startPos + 20]));
                    if(users[_userAddr].sharesOfLiquidation > 0) {
                        uint shareOfLiquidation = (amountOut * users[_userAddr].sharesOfLiquidation) / amountIn;
                        users[_userAddr].balanceDAI += shareOfLiquidation;
                        users[_userAddr].sharesOfLiquidation = 0;
                    }
                }
            }

            emit Liquidation(_price, amountIn, amountOut);
        }
    }

    
    /// @notice swapExactInputSingle swaps a fixed amount of DAI for a maximum possible amount of WETH9
    /// using the DAI/WETH9 0.3% pool by calling `exactInputSingle` in the swap router.
    /// @dev The calling address must approve this contract to spend at least `amountIn` worth of its DAI for this function to succeed.
    /// @param amountIn The exact amount of DAI that will be swapped for WETH9.
    /// @return amountOut The amount of WETH9 received.
    function Liquidate(uint256 amountIn) private returns (uint256 amountOut) {
// todo: secure so can only be run internally

        // Approve the router to spend WETH.
//        WETHToken.approve(address(swapRouter), amountIn);

        // Naively set amountOutMinimum to 0. In production, use an oracle or other data source to choose a safer value for amountOutMinimum.
        // We also set the sqrtPriceLimitx96 to be 0 to ensure we swap our exact input amount.
        ISwapRouter.ExactInputSingleParams memory params =
            ISwapRouter.ExactInputSingleParams({
                tokenIn: WMATIC,
                tokenOut: DAI,
                fee: poolFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });

        // The call to `exactInputSingle` executes the swap.
        // amountOut = swapRouter.exactInputSingle(params);  // orig for WETH swap
        //amountOut = swapRouter.exactInputSingle{value: msg.value}(params);    //itachi's code when manually called sending value an passing amount too
        amountOut = swapRouter.exactInputSingle{value: amountIn}(params);

        return amountOut;
    }



    /* 
    *   testing/development functions
    */
    
    /// @dev - used to simulate a drop in the price of ETH for testing
    /// _priceDrop is subtracted from the price of ETH returned by getLatestPrice()
    function zdevSetPriceDrop(int _priceDrop) external onlyOwners {
        priceDropAmount = _priceDrop;
    }

    
    // often it seems the aToken contract doesn't have enough matic to allow a user to burn aTokens
    // send matic to aave aToken contract using a separate account that's not part of the testing
    function zdevLoadMATIConATokenContract() external payable {
        WETHGateway.depositETH{value: msg.value}(pool, msg.sender, 0);
    }


    /// @dev transfers wMATIC from _addr to this contract
    function zdevAaveWMATICTransferFrom(address _addr, uint _amount) external returns (bool) {
        return AaveWMatic.transferFrom(_addr, address(this), _amount);
    }


    // get all tokens back out of the contract after finished testing
    function zdevRecoverMATIC() external onlyOwners {
        uint _balance = address(this).balance;
        msg.sender.call{value: _balance}("");
    }


    // get all tokens back out of the contract after finished testing
    function zdevRecoverDAI() external onlyOwners {
        uint256 amt = DAIToken.balanceOf(address(this));
        DAIToken.transfer(msg.sender, amt);
    }


    // transfer wMatic from smart contract to owner account
    function zdevRecoverAaveWMatic() external onlyOwners {
        uint256 _balance = AaveWMatic.balanceOf(address(this));
        AaveWMatic.transfer(msg.sender, _balance);
    }


    // withdraws MATIC before sending the contract's MATIC balance
    function zdevRecoverMatic() external onlyOwners {
        address thisContract = address(this);

        uint _amount = AaveWMatic.balanceOf(thisContract);
        AaveWMatic.approve(address(WETHGateway), _amount);
        WETHGateway.withdrawETH(pool, _amount, thisContract);
        
        uint _balance = thisContract.balance;
        msg.sender.call{value: _balance}("");
    }


    // withdraw matic + interest from aave by burning wMatic from the smart contract 
    // returns native token to the contract
    function zdevBurnContractATokens() external onlyOwners {
        address thisContract = address(this);
        uint256 balance = AaveWMatic.balanceOf(thisContract);

        AaveWMatic.approve(address(WETHGateway), balance);
        WETHGateway.withdrawETH(pool, balance, thisContract);
    }


    // This was for testing -> currently not in use
    function zdevGetAaveWMATICAllowanceGateway() external view returns(uint256){
        return AaveWMatic.allowance(address(this), address(WETHGateway));
    }


    /// @dev returns contract's WETH allowance approved by msg.sender
    // function zdevGetWETHAllowance() external view returns (uint) {
    //     return WETHToken.allowance(msg.sender, address(this));
    // }


    // /// @dev returns contract's WETH allowance approved by _addr
    // function zdevGetWETHAllowance(address _addr) external view returns (uint) {
    //     return WETHToken.allowance(_addr, address(this));
    // }
}
