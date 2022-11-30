// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../../lib/ds-test/test.sol";
import "../../lib/utils/Console.sol";
import "../../lib/utils/VyperDeployer.sol";
import "../IveFPIS.sol";


contract veFPISTest is DSTest {
    VyperDeployer vyperDeployer = new VyperDeployer();
    IveFPIS veFPIS;

    function setUp() public {
        ///@notice deploy a new instance of veFPIS by passing in the address of the deployed Vyper contract
        // def __init__(token_addr: address, _name: String[64], _symbol: String[32], _version: String[32]):
        // address token_addr = 0xc2544A32872A91F4A553b404C6950e89De901fdb;
        // string memory _name = "veFPIS";
        // string memory _symbol = "veFPIS";
        // string memory _version = "1.0.0";
        // bytes32 _name_bytes1 = "veFPIS";
        // bytes32 _name_bytes2 = "";
        // bytes32 _symbol_bytes = "veFPIS"; 
        // bytes32 _version_bytes = "1.0.0";

        address token_addr = 0xc2544A32872A91F4A553b404C6950e89De901fdb;
        string memory _name_bytes = "Vote-Escrowed FPIS";
        string memory _symbol_bytes = "veFPIS"; 
        string memory _version_bytes = "veFPIS_1.0.0";

        // for (uint i = 0; i < bytes(_name).length; i++) {
        //     _name_bytes[i] = bytes(_name)[i];
        // }

        emit log_bytes(abi.encode(token_addr, _name_bytes, _symbol_bytes, _version_bytes));

        veFPIS = IveFPIS(
            vyperDeployer.deployContract("veFXS", abi.encode(token_addr, _name_bytes, _symbol_bytes, _version_bytes)) //TODO: figure out how to pass in strings, potentially via bytes array conversion
        );

        emit log_named_address("veFPIS", address(veFPIS));
    }

    function testGet() public {
        address val = veFPIS.token();
        emit log_address(val);
    }

}
