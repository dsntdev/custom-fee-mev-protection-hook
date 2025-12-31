// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";

import { CustomFeeAntiMevHook } from "../src/CustomFeeAntiMevHook.sol";

import { HookMiner } from "v4-periphery/src/utils/HookMiner.sol";

import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";

/// @notice Deploys the CustomFeeAntiMevHook using a JSON config file.
contract DeployCustomFeeHookedV4PoolScript is Script {
    string internal constant MAINNET_CONFIG = "deploy-config/CustomFeeAntiMevHook.mainnet.json";
    string internal constant SEPOLIA_CONFIG = "deploy-config/CustomFeeAntiMevHook.sepolia.json";

    struct DeployConfig {
        uint256 chainId;
        address poolManager;
        address wrappedNative;
        address create2Deployer;
        address owner;
    }

    function run() external {
        uint256 privateKey = vm.envOr("PRIVATE_KEY", uint256(0));
        if (privateKey == 0) vm.startBroadcast();
        else vm.startBroadcast(privateKey);

        string memory configPath = vm.envOr("CONFIG_PATH", _defaultConfigPath());
        DeployConfig memory config = _loadConfig(configPath);
        require(block.chainid == config.chainId, "unexpected chain id");

        address deployer = privateKey == 0 ? tx.origin : vm.addr(privateKey);
        address wrappedNative = config.wrappedNative;
        IPoolManager manager = IPoolManager(config.poolManager);

        // --- Deploy hook at a valid flagged address via CREATE2 ---
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        bytes memory ctorArgs = abi.encode(manager, wrappedNative);

        (address expectedHookAddress, bytes32 salt) =
            HookMiner.find(config.create2Deployer, flags, type(CustomFeeAntiMevHook).creationCode, ctorArgs);

        CustomFeeAntiMevHook hook = new CustomFeeAntiMevHook{ salt: salt }(manager, wrappedNative);
        require(address(hook) == expectedHookAddress, "hook address mismatch");

        console2.log("Deployer:", deployer);
        console2.log("PoolManager:", address(manager));
        console2.log("WrappedNative:", wrappedNative);
        console2.log("Create2Deployer:", config.create2Deployer);
        console2.log("Hook:", address(hook));
        console2.log("Config:", configPath);

        vm.stopBroadcast();
    }

    function _defaultConfigPath() internal view returns (string memory) {
        if (block.chainid == 1) return MAINNET_CONFIG;
        if (block.chainid == 11_155_111) return SEPOLIA_CONFIG;
        return SEPOLIA_CONFIG;
    }

    function _loadConfig(string memory configPath) internal view returns (DeployConfig memory config) {
        string memory json = vm.readFile(configPath);
        config.chainId = vm.parseJsonUint(json, "$.chainId");
        config.poolManager = vm.parseJsonAddress(json, "$.poolManager");
        config.wrappedNative = vm.parseJsonAddress(json, "$.wrappedNative");
        config.create2Deployer = vm.parseJsonAddress(json, "$.create2Deployer");
    }
}
