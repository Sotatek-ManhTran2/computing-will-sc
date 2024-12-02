//SPDX-License-Identifier: MIT
// OpenZeppelin Contracts v5.x
pragma solidity 0.8.20;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {GenericWill} from "../common/GenericWill.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {ISafeGuard} from "../interfaces/ISafeGuard.sol";
import {ISafeWallet} from "../interfaces/ISafeWallet.sol";
import {Enum} from "@safe-global/safe-smart-account/contracts/libraries/Enum.sol";
import {ForwardingWillStruct} from "../libraries/ForwardingWillStruct.sol";

contract ForwardingWill is GenericWill {
  using EnumerableSet for EnumerableSet.AddressSet;

  /* Error */
  error NotBeneficiary();
  error DistributionUserInvalid();
  error DistributionAssetInvalid();
  error AssetInvalid();
  error PercentInvalid();
  error TotalPercentInvalid();
  error NotEnoughConditionalActive();
  error ExecTransactionFromModuleFailed();
  error BeneficiariesIsClaimed();

  /* State variable */
  uint128 public constant WILL_TYPE = 2;
  uint128 public constant MAX_TRANSFER = 100;

  EnumerableSet.AddressSet private _beneficiariesSet;
  mapping(address beneficiaries => uint256) public _distributions;

  /* View function */
  /**
   * @dev get beneficiaries list
   */
  function getBeneficiaries() external view returns (address[] memory) {
    return _beneficiariesSet.values();
  }

  /**
   * @dev Check activation conditions
   * @param guardAddress_ guard
   * @return bool true if eligible for activation, false otherwise
   */
  function checkActiveWill(address guardAddress_) external view returns (bool) {
    return _checkActiveWill(guardAddress_);
  }

  /* Main function */
  /**
   * @dev Initialize info will
   * @param willId_ will id
   * @param owner_ owner of will
   * @param distributions_ distributions list
   * @param config_ include lackOfOutgoingTxRange
   */
  function initialize(
    uint256 willId_,
    address owner_,
    ForwardingWillStruct.Distribution[] calldata distributions_,
    ForwardingWillStruct.WillExtraConfig calldata config_
  ) external notInitialized returns (uint256 numberOfBeneficiaries) {
    if (owner_ == address(0)) revert OwnerInvalid();

    //set info will
    _setWillInfo(willId_, owner_, 1, config_.lackOfOutgoingTxRange, msg.sender);
    numberOfBeneficiaries = _setDistributions(owner_, distributions_);
  }

  /**
   * @dev set distributions[]
   * @param sender_  sender address
   * @param distributions_ distributions
   */
  function setWillDistributions(
    address sender_,
    ForwardingWillStruct.Distribution[] calldata distributions_
  ) external onlyRouter onlyOwner(sender_) isActiveWill returns (uint256 numberOfBeneficiaries) {
    _clearDistributions();
    numberOfBeneficiaries = _setDistributions(sender_, distributions_);
  }

  /**
   * @dev Set lackOfOutgoingTxRange will
   * @param sender_  sender
   * @param lackOfOutgoingTxRange_  lackOfOutgoingTxRange
   */
  function setActivationTrigger(address sender_, uint128 lackOfOutgoingTxRange_) external onlyRouter onlyOwner(sender_) isActiveWill {
    _setActivationTrigger(lackOfOutgoingTxRange_);
  }

  /**
   * @param guardAddress_  guard address
   */
  function activeWill(address guardAddress_, address[] calldata assets_, bool isETH_) external onlyRouter returns (address[] memory assets) {
    if (_checkActiveWill(guardAddress_)) {
      if (getIsActiveWill() == 1) {
        _setWillToInactive();
      }
      assets = _transferAssetToBeneficiaries(assets_, isETH_);
    } else {
      revert NotEnoughConditionalActive();
    }
  }

  /* Utils function */

  /**
   * @dev Check activation conditions
   * @param guardAddress_ guard
   * @return bool true if eligible for activation, false otherwise
   */
  function _checkActiveWill(address guardAddress_) private view returns (bool) {
    uint256 lastTimestamp = ISafeGuard(guardAddress_).getLastTimestampTxs();
    uint256 lackOfOutgoingTxRange = uint256(getActivationTrigger());
    if (lastTimestamp + lackOfOutgoingTxRange > block.timestamp) {
      return false;
    }
    return true;
  }

  /**
   * @dev set distribution list
   * @param distributions_  distributions list
   * @return numberOfBeneficiaries number of beneficiaries
   */
  function _setDistributions(
    address owner_,
    ForwardingWillStruct.Distribution[] calldata distributions_
  ) internal returns (uint256 numberOfBeneficiaries) {
    uint256 totalPercent = 0;
    for (uint256 i = 0; i < distributions_.length; ) {
      _checkDistribution(owner_, distributions_[i]);
      _beneficiariesSet.add(distributions_[i].user);
      _distributions[distributions_[i].user] = distributions_[i].percent;
      totalPercent += distributions_[i].percent;
      unchecked {
        i++;
      }
    }
    if (totalPercent != 100) revert TotalPercentInvalid();

    numberOfBeneficiaries = _beneficiariesSet.length();
  }

  /**
   * @dev clear distributions list
   */
  function _clearDistributions() internal {
    address[] memory beneficiaries = _beneficiariesSet.values();
    for (uint256 i = 0; i < beneficiaries.length; ) {
      _beneficiariesSet.remove(beneficiaries[i]);
      _distributions[beneficiaries[i]] = 0;
      unchecked {
        i++;
      }
    }
  }

  /**
   * @dev check distribution
   * @param owner_ safe wallet address
   * @param distribution_ distribution
   */
  function _checkDistribution(address owner_, ForwardingWillStruct.Distribution calldata distribution_) private view {
    if (distribution_.percent == 0 || distribution_.percent > 100) revert DistributionAssetInvalid();
    if (distribution_.user == address(0) || distribution_.user == owner_ || _isContract(distribution_.user)) revert DistributionAssetInvalid();
  }

  /**
   * @dev transfer asset to beneficiaries
   */
  function _transferAssetToBeneficiaries(address[] calldata assets_, bool isETH_) private returns (address[] memory assets) {
    address safeAddress = getWillOwner();
    address[] memory beneficiaries = _beneficiariesSet.values();
    uint256 n = assets_.length;
    uint256 maxTransfer = MAX_TRANSFER;
    if (isETH_) {
      uint256 totalAmountEth = address(safeAddress).balance;
      if (totalAmountEth > 0) {
        for (uint256 i = 0; i < beneficiaries.length; ) {
          uint256 amount = (totalAmountEth * _distributions[beneficiaries[i]]) / 100;
          _transferEthToBeneficiary(safeAddress, beneficiaries[i], amount);
          unchecked {
            i++;
          }
        }
        maxTransfer = maxTransfer - beneficiaries.length;
      }
    }

    if (n * beneficiaries.length > maxTransfer) {
      n = maxTransfer / beneficiaries.length;
    }

    assets = new address[](n);
    for (uint256 i = 0; i < n; ) {
      uint256 totalAmountErc20 = IERC20(assets_[i]).balanceOf(safeAddress);
      assets[i] = assets_[i];
      if (totalAmountErc20 > 0) {
        for (uint256 j = 0; j < beneficiaries.length; ) {
          uint256 amount = (totalAmountErc20 * _distributions[beneficiaries[j]]) / 100;
          _transferErc20ToBeneficiary(assets_[i], safeAddress, beneficiaries[j], amount);

          unchecked {
            j++;
          }
        }
      }

      unchecked {
        i++;
      }
    }
  }

  /**
   * @dev transfer erc20 token to beneficiaries
   * @param erc20Address_  erc20 token address
   * @param from_ safe wallet address
   * @param to_ beneficiary address
   */
  function _transferErc20ToBeneficiary(address erc20Address_, address from_, address to_, uint256 amount) private {
    bytes memory transferErc20Data = abi.encodeWithSignature("transferToken(address,address,uint256)", erc20Address_, to_, amount);
    (bool transferErc20Success, bytes memory returnData) = ISafeWallet(from_).execTransactionFromModuleReturnData(
      from_,
      0,
      transferErc20Data,
      Enum.Operation.Call
    );
    if (!transferErc20Success || !abi.decode(returnData, (bool))) revert ExecTransactionFromModuleFailed();
  }

  /**
   * @dev transfer eth to beneficiaries
   * @param from_ safe wallet address
   * @param to_ beneficiary address
   */
  function _transferEthToBeneficiary(address from_, address to_, uint256 amount) private {
    bool transferEthSuccess = ISafeWallet(from_).execTransactionFromModule(to_, amount, "0x", Enum.Operation.Call);
    if (!transferEthSuccess) revert ExecTransactionFromModuleFailed();
  }

  /**
   * @dev check whether addr is a smart contract address or eoa address
   * @param addr  the address need to check
   *
   */
  function _isContract(address addr) private view returns (bool) {
    uint256 size;
    assembly ("memory-safe") {
      size := extcodesize(addr)
    }
    return size > 0;
  }
}
