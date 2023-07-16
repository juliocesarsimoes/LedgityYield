// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../../lib/forge-std/src/Test.sol";
import {ModifiersExpectations} from "../../_helpers/ModifiersExpectations.sol";

import {ERC20BaseUpgradeable} from "../../../../src/abstracts/base/ERC20BaseUpgradeable.sol";
import {GlobalOwner} from "../../../../src/GlobalOwner.sol";
import {GlobalPause} from "../../../../src/GlobalPause.sol";
import {GlobalBlacklist} from "../../../../src/GlobalBlacklist.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract TestedContract is ERC20BaseUpgradeable {
    function initialize(
        address globalOwner_,
        address globalPause_,
        address globalBlacklist_,
        string memory name_,
        string memory symbol_
    ) public initializer {
        __ERC20Base_init(globalOwner_, globalPause_, globalBlacklist_, name_, symbol_);
    }
}

contract Tests is Test, ModifiersExpectations {
    TestedContract tested;
    GlobalOwner globalOwner;
    GlobalPause globalPause;
    GlobalBlacklist globalBlacklist;
    string nameAtInitTime = "Dummy Token";
    string symbolAtInitTime = "DUMMY";

    function setUp() public {
        // Deploy GlobalOwner
        GlobalOwner impl = new GlobalOwner();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        globalOwner = GlobalOwner(address(proxy));
        globalOwner.initialize();
        vm.label(address(globalOwner), "GlobalOwner");

        // Deploy GlobalPause
        GlobalPause impl2 = new GlobalPause();
        ERC1967Proxy proxy2 = new ERC1967Proxy(address(impl2), "");
        globalPause = GlobalPause(address(proxy2));
        globalPause.initialize(address(globalOwner));
        vm.label(address(globalPause), "GlobalPause");

        // Deploy GlobalBlacklist
        GlobalBlacklist impl3 = new GlobalBlacklist();
        ERC1967Proxy proxy3 = new ERC1967Proxy(address(impl3), "");
        globalBlacklist = GlobalBlacklist(address(proxy3));
        globalBlacklist.initialize(address(globalOwner));
        vm.label(address(globalBlacklist), "GlobalBlacklist");

        // Deploy tested contract
        TestedContract impl4 = new TestedContract();
        ERC1967Proxy proxy4 = new ERC1967Proxy(address(impl4), "");
        tested = TestedContract(address(proxy4));
        tested.initialize(
            address(globalOwner),
            address(globalPause),
            address(globalBlacklist),
            nameAtInitTime,
            symbolAtInitTime
        );
        vm.label(address(tested), "TestedContract");
    }

    // =============================
    // === initialize() function ===
    function test_initialize_1() public {
        console.log("Should properly set global owner");
        assertEq(tested.globalOwner(), address(globalOwner));
    }

    function test_initialize_2() public {
        console.log("Should properly set global pause");
        assertEq(tested.globalPause(), address(globalPause));
    }

    function test_initialize_3() public {
        console.log("Should properly set global blacklist");
        assertEq(tested.globalBlacklist(), address(globalBlacklist));
    }

    function test_initialize_4() public {
        console.log("Should properly set ERC20 symbol");
        assertEq(tested.symbol(), symbolAtInitTime);
    }

    function test_initialize_5() public {
        console.log("Should properly set ERC20 name");
        assertEq(tested.name(), nameAtInitTime);
    }

    // ========================
    // === Tokens transfers ===
    function test_transfer_1() public {
        console.log("Should pause tokens transfers when paused");
        globalPause.pause();
        expectRevertPaused();
        tested.transfer(address(15), 50);
    }
}