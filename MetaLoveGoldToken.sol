pragma solidity 0.6.12;

import "./lib/BEP20.sol";

// MetaLoveGoldToken with Governance.
contract MetaLoveGoldToken is BEP20('Meta Love Gold', 'MLG') {
    /// @notice Creates `_amount` token to `_to`. Must only be called by the owner (MasterChef).
    function mint(address _to, uint256 _amount) external onlyOwner {
        _mint(_to, _amount);
    }
}