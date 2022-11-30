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


//TODO: gov topology
//TODO: styleguide
//TODO: events
//TODO: owned


interface IveFPIS {
    function locked__amount(address _t) external view returns (int128);
    function user_fpis_in_proxy() external view returns (mapping(address=>uint256));
    function token() external view returns (address);
    function transfer_to_proxy(address _staker_addr, int128 _transfer_amt) external;
    function proxy_pbk_liq_slsh( //TODO: consider simplifying into "payback" and "slash"
        address _staker_addr, 
        uint256 _non_liq_payback_amt, 
        uint256 _liq_payback_amt, 
        uint256 _liq_fee_amt, 
        uint256 _slash_amt
    ) external;
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
        uint256 maxUsageAllowedPercent; // TODO: consider packing, determine precision
        uint256 maxSlashAllowedPercent; // Percent of usage which may be slashed / taken as fees.
        bool custodiesFunds; // Percent of usage which may be held in custody by the app
    }

    struct User {
        // address[] appsInUse;
        mapping(address=>uint256) appToUsage;
    }

    uint256 private constant PRECISION = 1e6;

    IveFPIS immutable veFPIS;
    IERC20 immutable FPIS;
    address public timelock; //TODO: determine correct gov topology & CHANGE ONYLYOWNER

    /// @notice True if an app has been whitelisted to use the proxy
    mapping(address=>bool) public isApp;

    /// @notice Maps an app address to a struct containing its parameters
    mapping(address=>App) private addrToApp;

    /// @notice Maps a user address to a struct containing their permitted apps and usage in each app
    mapping(address=>User) private addrToUser;

    address[] allApps;


    modifier onlyApp() {
        require(isApp[msg.sender], "Only callable by app");
        _;
    }

    modifier noDoubleSpend(address userAddr) {
        _;

        int128 locked_int128 = veFPIS.locked__amount(_user);
        assert(locked_int128 >= 0, "FATAL: NEGATIVE LOCKED BALANCE"); // Should never happen
        uint256 locked = uint256(int256(locked_int128)); // Needs intermediate conversion since Solidity 0.8.0

        uint256 userFPISInProxy = veFPIS.user_fpis_in_proxy(userAddr);
        uint256 numApps = allApps.length;

        uint256 sumUsage = 0;
        uint256 sumSlashPotential = 0;

        for(uint i = 0; i < numApps; i++) {
            address appAddr = allApps[i];
            sumUsage = getUserAppUsage(appAddr, userAddr);
            sumSlashPotential = getUserAppPotentialSlash(appAddr, userAddr);
        }

        require(sumUsage == userFPISInProxy, "Proxy vs veFPIS accounting mismatch"); // TODO: code should never reach here, is this overkill? If so, remove summation from loop (gas), might be useful for security on apps
        require(sumUsage + sumSlashPotential <= locked, "Insufficient veFPIS balance to cover total usage + potential slash");        
    }

    constructor(address _owner, address _timelock, address _veFPIS) Owned(_owner) {
        veFPIS = IveFPIS(_veFPIS);
        FPIS = IERC20(veFPIS.token());
        timelock = _timelock;
    }

    /// @notice Whitelists an app to use the proxy and sets the max usage and max slash 
    function addApp(address appAddr, uint256 maxUsageAllowedPercent, uint256 maxSlashAllowedPercent, bool custodiesFunds) external onlyOwner {
        require(!isApp[appAddr], "veFPISProxy: app already added");
        isApp[_appAddr] = true;
        
        addrToApp[appAddr].maxUsageAllowedPercent = maxUsageAllowedPercent;
        addrToApp[appAddr].maxSlashAllowedPercent = maxSlashAllowedPercent;
        addrToApp[appAddr].custodiesFunds = custodiesFunds;

        allApps.push(appAddr);
    }

    // TODO: Is this safe?
    /// @notice Sets the max usage and max slash allowed for an app
    function setAppParams(address appAddr, uint256 maxUsageAllowedPercent, uint256 maxSlashAllowedPercent, bool custodiesFunds) external onlyOwner {
        require(isApp[msg.sender], "veFPISProxy: app nonexistant");
        addrToApp[appAddr].maxUsageAllowedPercent = maxUsageAllowedPercent;
        addrToApp[appAddr].maxSlashAllowedPercent = maxSlashAllowedPercent;
    }

    // TODO: Decide if this can be safely implemented
    // /// @notice Removes an app from the whitelist and sets its max allowances to 0
    // function removeApp(address appAddr) external onlyOwner {
    //     require(isApp[appAddr], "veFPISProxy: app nonexistant");
    //     isApp[appAddr] = false;
    //     addrToApp[appAddr].maxUsageAllowedPercent = 0; //TODO: is it better to omit these, case when removed but users still using.
    //     addrToApp[appAddr].maxSlashAllowedPercent = 0;
    //     addrToApp[appAddr].custodiesFunds = custodiesFunds;
    // }

    function setTimelock(address _timelock) external onlyOwner {
        timelock = _timelock;
    }

    function getAppParams(address appAddr) public view {
        return (addrToApp[appAddr].maxUsageAllowedPercent, addrToApp[appAddr].maxSlashAllowedPercent, addrToApp[appAddr].custodiesFunds);
    }

    function getUserAppUsage(address appAddr, address userAddr) public view {
        return (addrToUser[userAddr].appToUsage[appAddr]);
    }

    function getUserAppPotentialSlash(address appAddr, address userAddr) public view {
        return (getUserAppUsage(appAddr, userAddr) * addrToApp[appAddr].maxSlashAllowedPercent / PRECISION);
    }

    function getUserAppMaxUsage(address appAddr, address userAddr) public view {
        return (addrToApp[appAddr].maxUsageAllowedPercent * veFPIS.locked__amount(userAddr) / PRECISION);
    }

    // Unnecessary
    // function getUserAppMaxSlash(address _appAddr, address _userAddr) public view {
    //     return (getUserAppMaxUsage(_appAddr, _userAddr) * addrToApp[_appAddr].maxSlashAllowedPercent / PRECISION);
    // }

    function sendToApp(address appAddr, address userAddr, uint256 amountFPIS) public onlyApp noDoubleSpend(userAddr) {
        require (isApp[appAddr], "veFPISProxy: app nonexistant");
        App storage targetApp = addrToApp[appAddr];
        User storage targetUser = addrToUser[userAddr];

        require(getUserAppUsage(appAddr, userAddr) + amountFPIS <= getUserAppMaxUsage(appAddr, userAddr), "veFPISProxy: usage exceeds limit");

       veFPIS.transfer_to_proxy(userAddr, amountFPIS); //TODO: deal with int vs uint on _veFPISAmount
       FPIS.transfer(appAddr, amountFPIS);

       targetUser.appToUsage[appAddr] += amountFPIS;
    }

    /// @notice App must first approve the proxy to spend the amount of FPIS to payback
    function payback(address user, address appAddr, uint256 amountFPIS, bool isLiquidation) public onlyApp {
        require (isApp[_appAddr], "veFPISProxy: app nonexistant");
        App storage targetApp = addrToApp[_appAddr];
        User storage targetUser = addrToUser[_user];

        require (getUserAppUsage(appAddr, userAddr) >= amountFPIS, "veFPISProxy: payback amount exceeds usage");

        FPIS.transferFrom(appAddr, user, amountFPIS); //TODO: are return bool checks necessary?
        FPIS.approve(address(veFPIS), amountFPIS);

        if(isLiquidation) {
            veFPIS.proxy_pbk_liq_slsh(user, 0, amountFPIS, 0, 0);
        } else {
            veFPIS.proxy_pbk_liq_slsh(user, amountFPIS, 0, 0, 0);
        }

        targetUser.appToUsage[appAddr] -= amountFPIS;

    }

    function slashUsage(address user, address appAddr, uint256 amountFPIS, bool isFee, bool isLiquidation) public onlyApp {
        require (isApp[_appAddr], "veFPISProxy: app nonexistant");
        App storage targetApp = addrToApp[_appAddr];
        User storage targetUser = addrToUser[_user];

        require (getUserAppPotentialSlash(appAddr, userAddr) >= amountFPIS, "veFPISProxy: slash amount exceeds potential slash");

        if(isFee) {
            veFPIS.proxy_pbk_liq_slsh(user, 0, 0, amountFPIS, 0);
        } else {
            veFPIS.proxy_pbk_liq_slsh(user, 0, 0, 0, amountFPIS);
        }

        if(amountFPIS > getUserAppUsage(appAddr, userAddr)) {
            payback(user, appAddr, targetUser.appToUsage[appAddr], isLiquidation);
        } else {
            payback(user, appAddr, amountFPIS, isLiquidation);
        }
    }
    
    // TODO: Naked slash can result in double spend, do we need to enable anyways?
    // function slash(address _user, address _appAddr, uint256 _veFPISAmount) public{}
}