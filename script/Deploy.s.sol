// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {WillModule} from "../src/WillModule.sol";

/// Deploys WillModule at the SAME address on every chain (CREATE2 through the standard
/// deterministic deployer 0x4e59b44847b379578588920ca78fbf26c0b4956c). Same salt + same
/// constructor arguments => same address, which the multi-chain signatures rely on.
///
/// Usage, one chain at a time (same command, different --rpc-url):
///   forge script script/Deploy.s.sol --rpc-url robinhood_testnet --broadcast --private-key $PRIVATE_KEY
///   forge script script/Deploy.s.sol --rpc-url sepolia           --broadcast --private-key $PRIVATE_KEY
///   forge script script/Deploy.s.sol --rpc-url arbitrum_sepolia  --broadcast --private-key $PRIVATE_KEY
///   forge script script/Deploy.s.sol --rpc-url base_sepolia      --broadcast --private-key $PRIVATE_KEY
///
/// Env (optional): MIN_INTERVAL, MIN_DISPUTE in seconds. They MUST be identical on every chain
/// of one network family (all testnets, or all mainnets), or the addresses will differ.
///   Testnets default: 5 minutes each, so a full demo fits in a meeting.
///   Mainnets: e.g. MIN_INTERVAL=604800 (7d) MIN_DISPUTE=259200 (3d).
contract Deploy is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 constant SALT = keccak256("0xWills.WillModule.v3");

    function run() external returns (WillModule module) {
        uint64 minInterval = uint64(vm.envOr("MIN_INTERVAL", uint256(5 minutes)));
        uint64 minDispute = uint64(vm.envOr("MIN_DISPUTE", uint256(5 minutes)));
        bool testnet = !_isMainnet(block.chainid);
        if (!testnet) {
            require(minInterval >= 7 days && minDispute >= 3 days, "mainnet minimums too short");
        }
        require(CREATE2_DEPLOYER.code.length > 0, "deterministic deployer missing on this chain");

        bytes memory initCode = abi.encodePacked(type(WillModule).creationCode, abi.encode(minInterval, minDispute, testnet));
        address expected = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, SALT, keccak256(initCode)))))
        );

        if (expected.code.length > 0) {
            console.log("Already deployed at", expected);
            return WillModule(expected);
        }

        vm.startBroadcast();
        module = new WillModule{salt: SALT}(minInterval, minDispute, testnet);
        vm.stopBroadcast();

        require(address(module) == expected, "unexpected address");
        console.log("WillModule deployed at", address(module));
        console.log("chainId", block.chainid);
    }

    function _isMainnet(uint256 id) internal pure returns (bool) {
        return id == 1 || id == 42161 || id == 8453 || id == 10 || id == 137 || id == 4663;
    }
}
