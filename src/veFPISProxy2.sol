pragma solidity ^0.8.17;

// ====================================================================
// |     ______                   _______                             |
// |    / _____________ __  __   / ____(_____  ____ _____  ________   |
// |   / /_  / ___/ __ `| |/_/  / /_  / / __ \/ __ `/ __ \/ ___/ _ \  |
// |  / __/ / /  / /_/ _>  <   / __/ / / / / / /_/ / / / / /__/  __/  |
// | /_/   /_/   \__,_/_/|_|  /_/   /_/_/ /_/\__,_/_/ /_/\___/\___/   |
// |                                                                  |
// ====================================================================
// ============================ veFPISProxy ===========================
// ====================================================================
// Frax Finance: https://github.com/FraxFinance

// Primary Author(s)
// Jack Corddry: https://github.com/corddry


//TODO: governance topology & Owned import
//TODO: styleguide
//TODO: events
//TODO: decide if custodiesFunds variable is useful
//TODO: clean up natspec (less notices)
//TODO: Explore risk of setting parameters while user funds are in an app


interface IveFPIS {
    function locked__amount(address _t) external view returns (int128);
    function user_fpis_in_proxy() external view returns (mapping(address=>uint256));
    function token() external view returns (address);
    function transfer_from_app(address _staker_addr, address _app_addr, int128 _transfer_amt) external;
    function transfer_to_app(address _staker_addr, address _app_addr, int128 _transfer_amt) external;
    function proxy_add(address _staker_addr, uint128 _add_amt) external;
    function proxy_slash(address _staker_addr, uint128 _slash_amt) external;
}

interface IERC20 {
    function transfer(address _to, uint256 _amount) external returns (bool);
    function transferFrom(address _from, address _to, uint256 _amount) external returns (bool);
    function approve(address _spender, uint256 _amount) external returns (bool);
    function balanceOf(address _owner) external view returns (uint256 balance);
}

/// @title Manages any smart contract which can use a user's locked veFPIS balance as a sort of collateral
/// @dev Is given special permissiions in veFPIS.vy to transfer veFPIS to itself, and to slash or payback veFPIS
/// @dev Users cannot withdraw their veFPIS while they have a balance in the proxy
contract veFPISProxy is Owned {

    struct App {
        uint256 maxAllowancePercent; // What percent of a user's locked FPIS an app is able to control at max, 1e6 precision
        mapping (adddress=>uint256) userToAllowance; // The max amount of a user's FPIS which an app is able to control
        mapping (address=>uint256) userToFPISinApp; // The amount of a user's FPIS which is currently custodied in the app
    }

    uint256 private constant PRECISION = 1e6;

    IveFPIS immutable veFPIS;
    IERC20 immutable FPIS;
    address public timelock; //TODO: determine correct gov topology & CHANGE ONYLYOWNER

    /// @notice True if an app has been whitelisted to use the proxy
    mapping(address=>bool) public isApp;

    mapping(address=>App) private addrToApp;

    modifier onlyApp() {
        require(isApp[msg.sender], "Only callable by app");
        _;
    }

    constructor(address _owner, address _timelock, address _veFPIS) Owned(_owner) {
        veFPIS = IveFPIS(_veFPIS);
        FPIS = IERC20(veFPIS.token());
        timelock = _timelock;
    }

    /// @notice Whitelists an app to use the proxy and sets the max usage and max slash 
    function addApp(address appAddr, uint256 maxAllowancePercent) external onlyOwner {
        require(!isApp[appAddr], "veFPISProxy: app already added");
        isApp[_appAddr] = true;
        // allApps.push(appAddr);
        addrToApp[appAddr].maxAllowancePercent = maxAllowancePercent;
    }

    // TODO: ensure this is safe, should be since you can still repay if > allowed
    /// @notice Sets the max usage and max slash allowed for an app, reducing max usage restricts users to only exit but will not cause loss of funds
    function setAppMaxAllowancePercent(address appAddr, uint256 maxAllowancePercent) external onlyOwner {
        require(isApp[msg.sender], "veFPISProxy: app nonexistant");
        addrToApp[appAddr].maxAllowancePercent = maxAllowancePercent;
    }

    // // TODO: Is this safe? (traps user funds in app), preferred is probably just to set max allowance to 0
    // /// @notice Removes an app from the whitelist and sets its max allowances to 0
    // function removeApp(address appAddr) external onlyOwner {
    //     require(isApp[appAddr], "veFPISProxy: app nonexistant");
    //     isApp[appAddr] = false;
    //     maxUsageAllowedPercent[appAddr] = 0;
    // }

    function getAppMaxAllowancePercent(address appAddr) external view returns (uint256) {
        return addrToApp[appAddr].maxAllowancePercent;
    }

    function getUserFPISinApp(address userAddr, address appAddr) external view returns (uint256) {
        return addrToApp[appAddr].userToFPISinApp[userAddr];
    }

    function setTimelock(address _timelock) external onlyOwner {
        timelock = _timelock;
    }

    // /// @notice Returns the max number of a specific user's locked FPIS that a specific app may control
    // function getUserAppMaxUsage(address userAddr, address appAddr) public view {
    //     return (maxUsageAllowedPercent[appAddr] * veFPIS.locked__amount(userAddr) / PRECISION);
    // }

    /// @notice Moves funds from veFPIS.vy to an app and increases usage
    function appTransferFromVeFPIS(address userAddr, uint256 amountFPIS) public onlyApp {
        App storage app = addrToApp[msg.sender];
        require(app.userToFPISinApp[userAddr] + amountFPIS <= app.maxAllowancePercent * veFPIS.locked__amount(userAddr) / PRECISION, "veFPISProxy: usage exceeds limit");

        veFPIS.transfer_to_app(userAddr, appAddr, amountFPIS); //TODO: deal with int vs uint on _veFPISAmount

        app.userToFPISinApp[userAddr] += amountFPIS;
    }

    /// @notice Moves funds from an app to veFPIS.vy
    /// @dev App must first approve the proxy to spend the amount of FPIS to return
    function appReturnToVeFPIS(address userAddr, uint256 amountFPIS, bool isLiquidation) public onlyApp {
        App storage app = addrToApp[msg.sender];
        require (app.userToFPISinApp[userAddr] >= amountFPIS, "veFPISProxy: payback amount exceeds usage");

        veFPIS.transfer_from_app(userAddr, msg.sender, _transfer_amt); //TODO: Uint to int

        app.userToFPISinApp[userAddr] -= amountFPIS;
    }

    function appAdd(address userAddr, uint256 amountFPIS) public onlyApp {
        App storage app = addrToApp[msg.sender];
        
        veFPIS.proxy_add(userAddr, amountFPIS);

        uint256 userAppAllowance = app.userToAllowance[userAddr];
        uint256 userMaxAppAllowance = app.maxAllowancePercent * veFPIS.locked__amount(userAddr) / PRECISION;
        uint256 cap;

        if (userAppAllowance >= userMaxAppAllowance) {
            cap = userMaxAppAllowance;
        } else {
            cap = userAppAllowance;
        }

        uint256 newFPISinApp = app.userToFPISinApp[userAddr] += amountFPIS; //TODO ensure += has a uint return type

        if (newFPISinApp > cap) {
            uint256 surplus = newFPISinApp - cap;
            veFPIS.transfer_from_app(userAddr, msg.sender, surplus); //TODO: Uint to int
            app.userToFPISinApp[userAddr] -= surplus;
        }
    }

    function appSlash(address userAddr, uint256 amountFPIS) public onlyApp {
        App storage app = addrToApp[msg.sender];
        require (app.userToFPISinApp[userAddr] >= amountFPIS, "veFPISProxy: slash amount exceeds user FPIS in app");
        veFPIS.proxy_slash(userAddr, amountFPIS);
        app.userToFPISinApp[userAddr] -= amountFPIS;
    }
}