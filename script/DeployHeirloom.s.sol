// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {HeirloomVault} from "../src/HeirloomVault.sol";
import {HeirloomTypes as T} from "../src/HeirloomTypes.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title DeployHeirloom
/// @notice Deploys one HeirloomVault to Arc testnet (chain 5042002).
/// @dev UNAUDITED TESTNET CODE — DO NOT USE WITH REAL FUNDS.
///
///      Secrets: the deployer key is read from the PRIVATE_KEY environment
///      variable and is never written to disk, never logged, and never committed.
///      Everything else is configured through env vars too, so no address is
///      baked into the repository.
///
///      Arc facts this script asserts rather than assumes:
///        - USDC exposes SIX decimals. The script READS `decimals()` from the
///          configured asset and aborts if it is not 6, because every amount in
///          the vault is 6dp and an 18dp token would silently misprice every cap
///          by a factor of a trillion.
///        - Transfers to the zero address revert, so a zero payee is a
///          configuration bug that must fail before deployment, not after.
///        - Timestamps are non-decreasing rather than strictly increasing; the
///          contracts handle that with inclusive boundaries throughout.
contract DeployHeirloom is Script {
    /// @dev Arc testnet. RPC: https://rpc.testnet.arc.network
    uint256 internal constant ARC_TESTNET_CHAIN_ID = 5042002;

    /// @notice Production ladder from PRD §2: 90 / 180 / 270 / 365 days.
    function _defaultLadder() internal view returns (T.LadderConfig memory) {
        return T.LadderConfig({
            nagAfter: uint32(vm.envOr("HEIRLOOM_LADDER_NAG", uint256(90 days))),
            guardianAlertAfter: uint32(vm.envOr("HEIRLOOM_LADDER_ALERT", uint256(180 days))),
            careModeAfter: uint32(vm.envOr("HEIRLOOM_LADDER_CARE", uint256(270 days))),
            claimableAfter: uint32(vm.envOr("HEIRLOOM_LADDER_CLAIMABLE", uint256(365 days)))
        });
    }

    function run() external returns (HeirloomVault vault) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        HeirloomVault.InitParams memory params = _config();
        _preflight(params);

        vm.startBroadcast(deployerKey);
        vault = new HeirloomVault(params);
        vm.stopBroadcast();

        _report(vault, params);
    }

    /// @dev Every value comes from the environment; no address is baked into the
    ///      repository. Split out of `run` to keep each stack frame shallow.
    function _config() internal view returns (HeirloomVault.InitParams memory p) {
        // Ordered heirs: own cold backup -> spouse/family -> charity terminal.
        T.Beneficiary[] memory heirs = new T.Beneficiary[](3);
        heirs[0] = T.Beneficiary({
            payee: vm.envAddress("HEIRLOOM_HEIR_COLD_BACKUP"),
            window: uint32(vm.envOr("HEIRLOOM_WINDOW_TIER0", uint256(30 days)))
        });
        heirs[1] = T.Beneficiary({
            payee: vm.envAddress("HEIRLOOM_HEIR_FAMILY"),
            window: uint32(vm.envOr("HEIRLOOM_WINDOW_TIER1", uint256(60 days)))
        });
        // Terminal tier: the window is ignored, it never expires (invariant 6).
        heirs[2] = T.Beneficiary({payee: vm.envAddress("HEIRLOOM_HEIR_CHARITY"), window: 0});

        bytes32[] memory categories = new bytes32[](2);
        categories[0] = keccak256("BILLS");
        categories[1] = keccak256("MEDICAL");

        uint128[] memory caps = new uint128[](2);
        caps[0] = uint128(vm.envUint("HEIRLOOM_CARE_BILLS_CAP")); // 6dp
        caps[1] = uint128(vm.envUint("HEIRLOOM_CARE_MEDICAL_CAP")); // 6dp

        // Approved destinations per category. A care payment can only reach one
        // of these; the label alone proves nothing (docs/OPEN-QUESTIONS.md Q3).
        address[][] memory payees = new address[][](2);
        payees[0] = vm.envAddress("HEIRLOOM_CARE_BILLS_PAYEES", ",");
        payees[1] = vm.envAddress("HEIRLOOM_CARE_MEDICAL_PAYEES", ",");

        p = HeirloomVault.InitParams({
            owner: vm.envAddress("HEIRLOOM_OWNER"),
            asset: vm.envAddress("HEIRLOOM_USDC"),
            ladder: _defaultLadder(),
            guardians: vm.envAddress("HEIRLOOM_GUARDIANS", ","),
            threshold: vm.envUint("HEIRLOOM_GUARDIAN_THRESHOLD"),
            beneficiaries: heirs,
            careGuardian: vm.envAddress("HEIRLOOM_CARE_GUARDIAN"),
            careMonthlyCap: uint128(vm.envUint("HEIRLOOM_CARE_MONTHLY_CAP")), // 6dp
            carePeriod: uint32(vm.envOr("HEIRLOOM_CARE_PERIOD", uint256(30 days))),
            careCategories: categories,
            careCategoryCaps: caps,
            careCategoryPayees: payees
        });
    }

    /// @dev Fail before spending gas, not after.
    function _preflight(HeirloomVault.InitParams memory p) internal view {
        if (block.chainid != ARC_TESTNET_CHAIN_ID) {
            console2.log("WARNING: chain id is not Arc testnet (5042002). Got:", block.chainid);
        }

        // Arc USDC is 6dp and every cap is denominated in 6dp. A token with any
        // other precision would misprice the entire vault silently.
        require(IERC20Metadata(p.asset).decimals() == 6, "HEIRLOOM_USDC must expose 6 decimals (Arc USDC)");

        // Arc reverts on transfers to the zero address; catch it at config time.
        require(p.owner != address(0), "owner is zero");
        for (uint256 i = 0; i < p.beneficiaries.length; i++) {
            require(p.beneficiaries[i].payee != address(0), "a heir address is zero");
        }
        require(p.careGuardian != address(0), "care guardian is zero");

        // A category that can pay nobody is a dead end for the care guardian;
        // a zero destination would revert on Arc at payout time.
        for (uint256 c = 0; c < p.careCategoryPayees.length; c++) {
            require(p.careCategoryPayees[c].length > 0, "a care category has no approved payees");
            for (uint256 j = 0; j < p.careCategoryPayees[c].length; j++) {
                require(p.careCategoryPayees[c][j] != address(0), "a care payee is zero");
            }
        }

        require(p.threshold > 0 && p.threshold <= p.guardians.length, "guardian threshold unreachable");
    }

    function _report(HeirloomVault vault, HeirloomVault.InitParams memory p) internal view {
        console2.log("=== Heirloom vault deployed (UNAUDITED TESTNET CODE) ===");
        console2.log("vault:      ", address(vault));
        console2.log("owner:      ", vault.owner());
        console2.log("asset:      ", p.asset);
        console2.log("decimals:   ", IERC20Metadata(p.asset).decimals());
        console2.log("guardians:  ", p.guardians.length);
        console2.log("threshold:  ", p.threshold);
        console2.log("timelock(s):", vault.TIMELOCK());
        console2.log("state:      ", uint256(vault.state()), "(0 = Active)");
        console2.log("ladder nag/alert/care/claimable (s):");
        console2.log("  ", p.ladder.nagAfter, p.ladder.guardianAlertAfter);
        console2.log("  ", p.ladder.careModeAfter, p.ladder.claimableAfter);
        if (p.ladder.claimableAfter < 365 days) {
            console2.log("*** DEMO-ONLY VAULT: short ladder durations. Not a real safety net. ***");
        }
        console2.log("Do NOT send real funds to this contract.");
    }
}
