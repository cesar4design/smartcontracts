// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "./proxy/UUPSAccessControlUpgradeable.sol";
import "./interfaces/IToken.sol";
import "@chainlink/contracts/src/v0.8/KeeperCompatible.sol";

contract Token is
    Initializable,
    IERC20MetadataUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    KeeperCompatible,
    UUPSAccessControlUpgradeable,
    IToken
{
    using SafeMathUpgradeable for uint256;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;

    uint256 public constant PERCENTAGE_DENOMINATOR = 10000;
    uint256 public constant TOKEN_DECIMALS = 1e18;
    uint256 public constant TOKEN_INTERNAL_DECIMALS = 1e24;

    string public override name;
    string public override symbol;
    uint256 private _decimals;

    uint256 private tSupply;
    uint256 private excludeDebasingSupply;

    mapping(address => mapping(address => uint256)) private _allowances;

    mapping(address => uint256) private _balances;

    uint256 private treasuryBalance;
    address public treasuryWallet;

    uint256 public sellTaxRate;
    uint256 public debaseRate;

    uint256 public tokenScalingFactor;
    uint256 public debaseDuration;

    uint256 public holdingLimit;

    mapping(address => bool) public lpPools;
    mapping(address => bool) public isExcludedFromDebasing;
    mapping(address => bool) public isExcludedFromHoldingLimit;

    mapping(address => bool) public treasuryOperator;

    uint256 public lastTimeStamp;

    event Burn(address indexed from, uint256 amount);
    event Mint(address indexed to, uint256 amount);

    modifier onlyTreasuryOperator() {
        require(treasuryOperator[_msgSender()] || _msgSender() == owner());
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory _tokenName,
        string memory _tokenSymbol,
        uint256 _tSupply,
        address _tokenOwner,
        uint256 _sellTaxRate,
        uint256 _debaseRate,
        address _treasuryWallet
    ) external virtual initializer {
        __BscBank_init(
            _tokenName,
            _tokenSymbol,
            _tSupply,
            _sellTaxRate,
            _debaseRate,
            _treasuryWallet
        );
        transferOwnership(_tokenOwner);
        _excludedFromDebasing(_tokenOwner, true);
        _excludedFromHoldingLimit(_tokenOwner, true);
    }

    function __BscBank_init(
        string memory _tokenName,
        string memory _tokenSymbol,
        uint256 _tSupply,
        uint256 _sellTaxRate,
        uint256 _debaseRate,
        address _treasuryWallet
    ) internal onlyInitializing {
        __UUPSAccessControlUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __BscBank_init_unchained(
            _tokenName,
            _tokenSymbol,
            _tSupply,
            _sellTaxRate,
            _debaseRate,
            _treasuryWallet
        );
    }

    function __BscBank_init_unchained(
        string memory _tokenName,
        string memory _tokenSymbol,
        uint256 _tSupply,
        uint256 _sellTaxRate,
        uint256 _debaseRate,
        address _treasuryWallet
    ) internal onlyInitializing {
        name = _tokenName;
        symbol = _tokenSymbol;
        _decimals = 18;

        tSupply = _tSupply * TOKEN_DECIMALS;
        excludeDebasingSupply = tSupply;

        holdingLimit = (tSupply * 100) / PERCENTAGE_DENOMINATOR;

        sellTaxRate = _sellTaxRate;
        debaseRate = _debaseRate;

        tokenScalingFactor = TOKEN_DECIMALS;
        debaseDuration = 86400;
        treasuryBalance = 0;

        lastTimeStamp = block.timestamp;

        treasuryWallet = _treasuryWallet;

        _excludedFromDebasing(owner(), true);
        _excludedFromHoldingLimit(owner(), true);
        

        _excludedFromDebasing(treasuryWallet, true);
        _excludedFromHoldingLimit(treasuryWallet, true);

        _balances[owner()] = _fragmentToDebaseTokenWithBase(tSupply);

        pause();

        emit Transfer(address(0), msg.sender, tSupply);
    }

    receive() external payable {}

    function withdrawETH(address _to) external onlyOwner {
        require(_to != address(0), "Invalid address: zero address");
        (bool success, ) = payable(_to).call{value: address(this).balance}("");
        if(!success) {
            revert("Trasnfer Failed");
        }
    }

    function totalSupply() public view override returns (uint256) {
        return tSupply + treasuryBalance;
    }

    function decimals() external view override returns (uint8) {
        return uint8(_decimals);
    }

    function balanceOf(
        address _account
    ) public view override returns (uint256) {
        if (isExcludedFromDebasing[_account]) {
            if (_account == treasuryWallet) {
                return _treasuryBalanceOf();
            }
            return _debaseTokenToFragmentWithBase(_balances[_account]);
        }
        return _debaseTokenToFragment(_balances[_account]);
    }

    function balanceOfUnderlying(
        address _account
    ) public view returns (uint256) {
        return _balances[_account];
    }

    function transfer(
        address _recipient,
        uint256 _amount
    ) public override returns (bool) {
        _transfer(_msgSender(), _recipient, _amount);
        return true;
    }

    function allowance(
        address _holder,
        address _spender
    ) public view override returns (uint256) {
        return _allowances[_holder][_spender];
    }

    function approve(
        address _spender,
        uint256 _amount
    ) public override returns (bool) {
        _approve(_msgSender(), _spender, _amount);
        return true;
    }

    function transferFrom(
        address _sender,
        address _recipient,
        uint256 _amount
    ) public override returns (bool) {
        _transfer(_sender, _recipient, _amount);
        _approve(
            _sender,
            _msgSender(),
            _allowances[_sender][_msgSender()].sub(
                _amount,
                "BEP20: transfer amount exceeds allowance"
            )
        );
        return true;
    }

    function increaseAllowance(
        address _spender,
        uint256 _addedValue
    ) public virtual returns (bool) {
        _approve(
            _msgSender(),
            _spender,
            _allowances[_msgSender()][_spender].add(_addedValue)
        );
        return true;
    }

    function decreaseAllowance(
        address _spender,
        uint256 _subtractedValue
    ) public virtual returns (bool) {
        _approve(
            _msgSender(),
            _spender,
            _allowances[_msgSender()][_spender].sub(
                _subtractedValue,
                "BEP20: decreased allowance below zero"
            )
        );
        return true;
    }

    function _approve(
        address _holder,
        address _spender,
        uint256 _amount
    ) internal virtual {
        require(_holder != address(0), "ERC20: approve from the zero address");
        require(_spender != address(0), "ERC20: approve to the zero address");

        _allowances[_holder][_spender] = _amount;
        emit Approval(_holder, _spender, _amount);
    }

    function _mint(address _to, uint256 _amount) internal {
        if (_to == address(0)) {
            revert("Not acceptable to mint!");
        }

        tSupply += _amount;

        uint256 debaseTokenAmount = _fragmentToDebaseToken(_amount);
        if (isExcludedFromDebasing[_to]) {
            excludeDebasingSupply += _amount;
            debaseTokenAmount = _fragmentToDebaseTokenWithBase(_amount);
        }

        _balances[_to] += debaseTokenAmount;

        emit Mint(_to, _amount);
        if (_to != treasuryWallet) {
            emit Transfer(address(0), _to, _amount);
        }
    }

    function _burn(address _from, uint256 _amount) internal {
        if (_from == address(0)) {
            revert("Not acceptable to burn!");
        }

        tSupply -= _amount;

        uint256 debaseTokenAmount = _fragmentToDebaseToken(_amount);
        if (isExcludedFromDebasing[_from]) {
            excludeDebasingSupply -= _amount;
            debaseTokenAmount = _fragmentToDebaseTokenWithBase(_amount);
        }

        _balances[_from] -= debaseTokenAmount;

        emit Burn(_from, _amount);
        emit Transfer(_from, address(0), _amount);
    }

    function _transfer(
       address _from,
       address _to,
       uint256 _amount
    ) internal whenNotPaused {
       require(_from != address(0), "ERC20: transfer from the zero address");
       require(_to != address(0), "ERC20: transfer to the zero address");

        if (balanceOf(_from) < _amount) {
            revert("Insufficient Funds For Transfer");
        }

        if (balanceOf(_to) >= holdingLimit && !isExcludedFromHoldingLimit[_to]) {
            revert("Holding Tokens exceeded!");
        }

        uint256 amount = _amount;

        if (!isExcludedFromHoldingLimit[_to] && balanceOf(_to) + amount > holdingLimit) {
            amount = amount - (balanceOf(_to) + amount - holdingLimit);
        }

        uint256 debaseToken = _fragmentToDebaseToken(amount);
        uint256 sellTax = 0;

        if (_from != owner() && lpPools[_to]) {
            sellTax = (amount * sellTaxRate) / PERCENTAGE_DENOMINATOR;
        }

        uint256 amountAfterTax = amount - sellTax;
        uint256 debaseTokenAfterTax = _fragmentToDebaseToken(amountAfterTax);
        uint256 adjustedBalance = isExcludedFromDebasing[_to] ? _fragmentToDebaseTokenWithBase(amountAfterTax) : debaseTokenAfterTax;

        _balances[_from] -= debaseToken;

        if (isExcludedFromDebasing[_to]) {
            _balances[_to] += adjustedBalance;
        } else {
           _balances[_to] += debaseTokenAfterTax;
        }

        treasuryBalance += sellTax;
        tSupply -= sellTax;

        emit Transfer(_from, _to, amountAfterTax);

        if (sellTax > 0) {
           emit Transfer(_from, treasuryWallet, sellTax);
        }

        // Update excludeDebasingSupply based on the transfer
        if (!isExcludedFromDebasing[_from] && isExcludedFromDebasing[_to]) {
            excludeDebasingSupply += amountAfterTax;
        }

        if (isExcludedFromDebasing[_from] && !isExcludedFromDebasing[_to]) {
            excludeDebasingSupply -= amountAfterTax;
        }

        // Ensure that treasuryBalance updates are accounted for
        if (treasuryBalance > 0) {
            _sendTokensTreasuryWallet(treasuryBalance, treasuryWallet);
        }
    }

    function _sendTokensTreasuryWallet(uint256 _amount, address _to) internal {
        require(treasuryBalance >= _amount, "Insufficient Balance to claim");
        treasuryBalance -= _amount;
        _mint(_to, _amount);
    }

    function claimFromTreasury(
        address _to,
        uint256 _amount
    ) external whenNotPaused onlyTreasuryOperator {
        if (treasuryBalance > 0) {
            _sendTokensTreasuryWallet(treasuryBalance, treasuryWallet);
        }

        if (isExcludedFromDebasing[_to]) {
            _balances[_to] += _fragmentToDebaseTokenWithBase(_amount);
        } else {
            _balances[_to] += _fragmentToDebaseToken(_amount);
        }

        _balances[treasuryWallet] -= _fragmentToDebaseTokenWithBase(_amount);

        emit Transfer(treasuryWallet, _to, _amount);
    }

    function checkUpkeep(
        bytes calldata checkData
    )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        upkeepNeeded = (block.timestamp - lastTimeStamp) > debaseDuration;
        performData = checkData;

        return (upkeepNeeded, performData);
    }

    function performUpkeep(bytes calldata /* performData */) external override {
        //We highly recommend revalidating the upkeep in the performUpkeep function
        require(
            (block.timestamp - lastTimeStamp) > debaseDuration,
            "KeepUp requirement is not met!"
        );

        require(tSupply >= excludeDebasingSupply, "tSupply must be greater than or equal to excludeDebasingSupply");

         _debase();

        lastTimeStamp = block.timestamp;
    }

    function _debase() private whenNotPaused {
        uint256 ratio = (debaseRate * TOKEN_DECIMALS) / PERCENTAGE_DENOMINATOR;

        uint256 preDebasingSupply = tSupply - excludeDebasingSupply;

        tokenScalingFactor =
            (tokenScalingFactor * (TOKEN_DECIMALS - ratio)) /
            TOKEN_DECIMALS;
        uint256 debasingSupply = (preDebasingSupply *
            (TOKEN_DECIMALS - ratio)) / TOKEN_DECIMALS;

        uint256 debasedTokenAmount = preDebasingSupply - debasingSupply;

        treasuryBalance += debasedTokenAmount;
        tSupply -= debasedTokenAmount;
    }

    function debaseTokenToFragment(
        uint256 _debaseToken
    ) public view returns (uint256) {
        return _debaseTokenToFragment(_debaseToken);
    }

    function fragmentToDebaseToken(
        uint256 _fragment
    ) public view returns (uint256) {
        return _fragmentToDebaseToken(_fragment);
    }

    // 10^24 --> 10^18
    function _debaseTokenToFragmentWithBase(
        uint256 _debaseToken
    ) internal pure returns (uint256) {
        return _debaseToken.mul(TOKEN_DECIMALS).div(TOKEN_INTERNAL_DECIMALS);
    }

    // 10^24 --> 10^18
    function _debaseTokenToFragment(
        uint256 _debaseToken
    ) internal view returns (uint256) {
        return
            _debaseToken.mul(tokenScalingFactor).div(TOKEN_INTERNAL_DECIMALS);
    }

    //10^18 --> 10^24
    function _fragmentToDebaseToken(
        uint256 _value
    ) internal view returns (uint256) {
        return _value.mul(TOKEN_INTERNAL_DECIMALS).div(tokenScalingFactor);
    }
    //10^18 --> 10^24
    function _fragmentToDebaseTokenWithBase(
        uint256 _value
    ) internal pure returns (uint256) {
        return _value.mul(TOKEN_INTERNAL_DECIMALS).div(TOKEN_DECIMALS);
    }

    /*
     * Contract Owner Settings
     */

    function updateSellTaxRate(uint256 _sellTaxRate) external onlyOwner {
        // 100 : 1%
        require(
            _sellTaxRate <= 5000,
            "Rate should be less than PERCENTAGE_DENOMINATOR"
        );
        sellTaxRate = _sellTaxRate;
    }

    function updateHoldingLimit(uint256 _holdingLimit) external onlyOwner {
        holdingLimit = _holdingLimit;
    }

    function updateDebaseRate(uint256 _debaseRate) external onlyOwner {
        // 100 : 1%
        require(
            _debaseRate <= PERCENTAGE_DENOMINATOR,
            "Rate should be less than PERCENTAGE_DENOMINATOR"
        );
        debaseRate = _debaseRate;
    }

    function updateDebaseDuration(uint256 _debaseDuration) external onlyOwner {
        debaseDuration = _debaseDuration;
    }

    function updateLPPool(address _lpPool, bool _isLPPool) external onlyOwner {
        require(_lpPool != address(0), "LP Pool address shouldn't be zero!");
        lpPools[_lpPool] = _isLPPool;
        _excludedFromDebasing(_lpPool, _isLPPool);
        _excludedFromHoldingLimit(_lpPool, _isLPPool);
    }

    function updateTreasuryOperator(
        address _addr,
        bool _isOperator
    ) external onlyOwner {
        require(_addr != address(0), "Operator shouldn't be zero.");
        treasuryOperator[_addr] = _isOperator;
    }

    function _excludedFromDebasing(
        address _account,
        bool _isExcluded
    ) internal {
        require(_account != address(0), "Account shouldn't be zero.");

        bool prevIsExcluded = isExcludedFromDebasing[_account];
        uint256 prevBalance = balanceOf(_account);

        if (prevIsExcluded != _isExcluded) {
            isExcludedFromDebasing[_account] = _isExcluded;

            if (_isExcluded) {
               // Account is being excluded
                _balances[_account] = _fragmentToDebaseTokenWithBase(prevBalance);
                excludeDebasingSupply += _balances[_account];
            } else {
                // Account is being included
                _balances[_account] = _fragmentToDebaseToken(prevBalance);
                excludeDebasingSupply -= _balances[_account];
            }
        }
    }


    function multiExcludedFromDebasing(
        address[] memory _accounts,
        bool _isExcluded
    ) public onlyOwner {
        for (uint i = 0; i < _accounts.length; ++i) {
            require(_accounts[i] != treasuryWallet, "Treasury wallet cannot be included in debasing");
            _excludedFromDebasing(_accounts[i], _isExcluded);
        }
    }

    function _excludedFromHoldingLimit(
        address _account,
        bool _isExcluded
    ) internal {
        require(_account != address(0), "Account shouldn't be zero.");
        isExcludedFromHoldingLimit[_account] = _isExcluded;
    }

    function multiExcludedFromHoldingLimit(
        address[] memory _accounts,
        bool _isExcluded
    ) public onlyOwner {
        for (uint i = 0; i < _accounts.length; ++i) {
            _excludedFromHoldingLimit(_accounts[i], _isExcluded);
        }
    }

    function multiAirdropTokenRequested(
        address[] memory _airdroppers,
        uint256[] memory _amounts
    ) external nonReentrant whenNotPaused {
        require(_airdroppers.length == _amounts.length, "Arrays length mismatch");

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < _amounts.length; ++i) {
            totalAmount += _amounts[i];
        }
    
        require(balanceOf(msg.sender) >= totalAmount, "Insufficient balance");

        for (uint256 i = 0; i < _airdroppers.length; ++i) {
            if (balanceOf(msg.sender) > _amounts[i]) {
                if (isExcludedFromDebasing[msg.sender]) {
                    _balances[msg.sender] -= _fragmentToDebaseTokenWithBase(
                        _amounts[i]
                    );
                    excludeDebasingSupply -= _amounts[i];
                } else {
                    _balances[msg.sender] -= _fragmentToDebaseToken(
                        _amounts[i]
                    );
                }

                if (isExcludedFromDebasing[_airdroppers[i]]) {
                    _balances[
                        _airdroppers[i]
                    ] += _fragmentToDebaseTokenWithBase(_amounts[i]);
                    excludeDebasingSupply += _amounts[i];
                } else {
                    _balances[_airdroppers[i]] += _fragmentToDebaseToken(
                        _amounts[i]
                    );
                }

                emit Transfer(msg.sender, _airdroppers[i], _amounts[i]);
            }
        }
    }

    function setLastTime() external onlyOwner {
        require(lastTimeStamp <= block.timestamp);
        lastTimeStamp = block.timestamp;
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    /*
     * View functions
     */
    function getOwner() external view returns (address) {
        return owner();
    }

    function _treasuryBalanceOf() internal view returns (uint256) {
        uint256 realBalance = _debaseTokenToFragmentWithBase(
            _balances[treasuryWallet]
        );
        return treasuryBalance + realBalance;
    }
}
