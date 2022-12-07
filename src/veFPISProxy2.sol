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

    // struct App {
    //     uint256 maxUsageAllowedPercent; // Usage: how much of a user's locked FPIS an app controls // TODO: consider packing, determine precision
    //     uint256 maxSlashAllowedPercent; // Percent of usage which may be slashed / taken as fees.
    //     bool custodiesFunds; // Percent of usage which may be held in custody by the app
    // }

    // struct User {
    //     // address[] appsInUse;
    //     mapping(address=>uint256) appToUsage;
    // }

    // /// @notice Maps an app address to a struct containing its parameters
    // mapping(address=>App) private addrToApp;

    // /// @notice Maps a user address to a struct containing their permitted apps and usage in each app
    // mapping(address=>User) private addrToUser;

    uint256 private constant PRECISION = 1e6;

    IveFPIS immutable veFPIS;
    IERC20 immutable FPIS;
    address public timelock; //TODO: determine correct gov topology & CHANGE ONYLYOWNER

    /// @notice True if an app has been whitelisted to use the proxy
    mapping(address=>bool) public isApp;

    /// @notice Maps a user's address to a mapping from app address to how much of their locked veFPIS balance is being used by that app
    mapping(address=>mapping(address=>uint256)) private userToAppToUsage;

    // @notice Maps an app's address to the percent of a user's locked veFPIS balance which may be used by that app (1e6 precision)
    mapping(address=>uint256) private maxUsageAllowedPercent;

    /// @notice all apps which have ever been whitelisted
    address[] allApps;


    modifier onlyApp() {
        require(isApp[msg.sender], "Only callable by app");
        _;
    }

    // /// @notice Ensures that after a function call, the user's usage + slash potential is not greater than their locked balance
    // modifier noDoubleSpend(address userAddr) {
    //     _;

    //     int128 locked_int128 = veFPIS.locked__amount(_user);
    //     assert(locked_int128 >= 0, "FATAL: NEGATIVE LOCKED BALANCE"); // Should never happen
    //     uint256 locked = uint256(int256(locked_int128)); // Needs intermediate conversion since Solidity 0.8.0

    //     uint256 userFPISInProxy = veFPIS.user_fpis_in_proxy(userAddr);
    //     uint256 numApps = allApps.length;

    //     uint256 sumUsage = 0;
    //     uint256 sumSlashPotential = 0;

    //     for(uint i = 0; i < numApps; i++) {
    //         address appAddr = allApps[i];
    //         sumUsage = getUserAppUsage(appAddr, userAddr);
    //         sumSlashPotential = getUserAppPotentialSlash(appAddr, userAddr);
    //     }

    //     require(sumUsage == userFPISInProxy, "Proxy vs veFPIS accounting mismatch"); // TODO: code should never reach here, is this overkill? If so, remove summation from loop (gas), might be useful for security on apps
    //     require(sumUsage + sumSlashPotential <= locked, "Insufficient veFPIS balance to cover total usage + potential slash");        
    // }

    constructor(address _owner, address _timelock, address _veFPIS) Owned(_owner) {
        veFPIS = IveFPIS(_veFPIS);
        FPIS = IERC20(veFPIS.token());
        timelock = _timelock;
    }

    /// @notice Whitelists an app to use the proxy and sets the max usage and max slash 
    function addApp(address appAddr, uint256 newMaxUsageAllowedPercent) external onlyOwner {
        require(!isApp[appAddr], "veFPISProxy: app already added");
        isApp[_appAddr] = true;
        maxUsageAllowedPercent[appAddr] = newMaxUsageAllowedPercent;
        
        // addrToApp[appAddr].maxUsageAllowedPercent = maxUsageAllowedPercent;
        // addrToApp[appAddr].maxSlashAllowedPercent = maxSlashAllowedPercent;
        // addrToApp[appAddr].custodiesFunds = custodiesFunds;

        allApps.push(appAddr);
    }

    // TODO: Is this safe?
    /// @notice Sets the max usage and max slash allowed for an app
    function setAppMaxUsage(address appAddr, uint256 newMaxUsageAllowedPercent) external onlyOwner {
        require(isApp[msg.sender], "veFPISProxy: app nonexistant");
        maxUsageAllowedPercent[appAddr] = newMaxUsageAllowedPercent;
    }

    // TODO: Decide if this can be safely implemented
    // /// @notice Removes an app from the whitelist and sets its max allowances to 0
    // function removeApp(address appAddr) external onlyOwner {
    //     require(isApp[appAddr], "veFPISProxy: app nonexistant");
    //     isApp[appAddr] = false;
    //     maxUsageAllowedPercent[appAddr] = 0;
    // }

    function getAppMaxUsage(address appAddr) external view returns (uint256) {
        return maxUsageAllowedPercent[appAddr];
    }

    function getUserAppUsage(address userAddr, address appAddr) external view returns (uint256) {
        return userToAppToUsage[userAddr][appAddr];
    }

    function setTimelock(address _timelock) external onlyOwner {
        timelock = _timelock;
    }

    /// @notice Returns the max number of a specific user's locked FPIS that a specific app may control
    function getUserAppMaxUsage(address userAddr, address appAddr) public view {
        return (maxUsageAllowedPercent[appAddr] * veFPIS.locked__amount(userAddr) / PRECISION);
    }

    /// @notice Moves funds from veFPIS.vy to an app and increases usage
    /// @dev uses noDoubleSpend modifier to ensure that the user's usage + slash potential is not greater than their locked balance
    function sendToApp(address appAddr, address userAddr, uint256 amountFPIS) public onlyApp {
        require (isApp[appAddr], "veFPISProxy: app nonexistant");
        require(getUserAppUsage(userAddr, appAddr) + amountFPIS <= getUserAppMaxUsage(userAddr, appAddr), "veFPISProxy: usage exceeds limit");

       veFPIS.transfer_to_app(userAddr, appAddr, amountFPIS); //TODO: deal with int vs uint on _veFPISAmount
       FPIS.transfer(appAddr, amountFPIS);

       userToAppToUsage[userAddr][appAddr] += amountFPIS;
    }

    /// @notice Moves funds from an app to veFPIS.vy and 
    /// @dev App must first approve the proxy to spend the amount of FPIS to payback
    function payback(address userAddr, address appAddr, uint256 amountFPIS, bool isLiquidation) public onlyApp {
        require (isApp[_appAddr], "veFPISProxy: app nonexistant");
        require (getUserAppUsage(userAddr, appAddr) >= amountFPIS, "veFPISProxy: payback amount exceeds usage");

        veFPIS.transfer_from_app(userAddr, appAddr, _transfer_amt); //TODO: Uint to int

        userToAppToUsage[userAddr][appAddr] -= amountFPIS;
    }

    function appAdd(address userAddr, address appAddr, uint256 amountFPIS) public onlyApp {
        require (isApp[_appAddr], "veFPISProxy: app nonexistant");
        veFPIS.proxy_add(userAddr, amountFPIS);
        userToAppToUsage[userAddr][appAddr] += amountFPIS; //TODO: what if this exceeds max allowed?
    }

    function appSlasb(address userAddr, address appAddr, uint256 amountFPIS) public onlyApp {
        require (isApp[_appAddr], "veFPISProxy: app nonexistant");
        require (userToAppToUsage[userAddr][appAddr] >= amountFPIS, "veFPISProxy: slash amount exceeds usage");
        veFPIS.proxy_slash(userAddr, amountFPIS);
        userToAppToUsage[userAddr][appAddr] -= amountFPIS;
    }

    // /// @notice Slashes a user and pays down their usage
    // /// @dev Slashed amount remains in the app's custody
    // /// @dev App must first approve the proxy to spend the amount of FPIS to payback
    // /// @dev a raw slash without a corresponding payback can result in double spend issues as locked balance decreases but maximum potential slash does not
    // /// @dev the only way to decrease user_fpis_in_proxy in veFPIS.vy is via payback, which makes this necessary
    // function slashUsage(address user, address appAddr, uint256 amountFPIS, bool isFee, bool isLiquidation) public onlyApp {
    //     require (isApp[_appAddr], "veFPISProxy: app nonexistant");
    //     App storage targetApp = addrToApp[_appAddr];
    //     User storage targetUser = addrToUser[_user];

    //     require (getUserAppPotentialSlash(appAddr, userAddr) >= amountFPIS, "veFPISProxy: slash amount exceeds potential slash");

    //     if(isFee) {
    //         veFPIS.proxy_pbk_liq_slsh(user, 0, 0, amountFPIS, 0);
    //     } else {
    //         veFPIS.proxy_pbk_liq_slsh(user, 0, 0, 0, amountFPIS);
    //     }

    //     if(amountFPIS > getUserAppUsage(appAddr, userAddr)) {
    //         payback(user, appAddr, targetUser.appToUsage[appAddr], isLiquidation);
    //     } else {
    //         payback(user, appAddr, amountFPIS, isLiquidation);
    //     }
    // }
    
    // // TODO: Naked slash can result in double spend, do we need to enable anyways?
    // // function slash(address _user, address _appAddr, uint256 _veFPISAmount) public{}
}