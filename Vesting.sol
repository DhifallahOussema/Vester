import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";



contract Light is ERC20, ERC20Burnable, Ownable {

    constructor() ERC20("Light", "Lts") {}
    function burn(uint256 amount) public override{
   
    _burn(msg.sender, amount);

    }
    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }
    function decimals() public override view returns(uint8){
        return 8;
    }
}
contract LightVesting is Ownable {
    struct Schedule {
        uint256 totalAmount;
        uint256 claimedAmount;
        uint256 startTime;
        uint256 cliffTime;
        uint256 endTime;
        address asset;
        uint256 startamount;
        bool isFixed;
    }

    // user => scheduleId => schedule
    mapping(address => mapping(uint256 => Schedule)) public schedules;
    mapping(address => uint256) public numberOfSchedules;

    mapping(address => uint256) public locked;

    event Claim(address indexed claimer, uint256 amount);
    event Vest(address indexed to, uint256 amount);
    event Cancelled(address account);

    constructor() {}

    /**
     * @notice Sets up a vesting schedule for a set user.
     * @dev adds a new Schedule to the schedules mapping.
     * @param beneficiary the account that a vesting schedule is being set up for. Will be able to claim tokens after
     *                the cliff period.
     * @param amount the amount of tokens being vested for the user.
     * @param asset the asset that the user is being vested
     * @param cliffWeeks the number of weeks that the cliff will be present at.
     * @param vestingWeeks the number of weeks the tokens will vest over (linearly)
     * @param daystostart the timestamp for when this vesting should have started
     */
    function vest(
        address beneficiary,
        uint256 amount,
        address asset,
        uint256 cliffWeeks,
        uint256 vestingWeeks,
        uint256 daystostart,
        uint256 startamount,
        bool isFixed
    ) public onlyOwner {
        // ensure cliff is shorter than vesting
        require(
            vestingWeeks >= 0 && vestingWeeks >= cliffWeeks && amount > 0,
            "Vesting: invalid vesting params"
        );

        uint256 currentLocked = locked[asset];

        // require the token is present
        require(
            IERC20(asset).balanceOf(address(this)) >= currentLocked + amount,
            "Vesting: Not enough tokens"
        );
        uint256 startTime = daystostart * 1 days;
        // create the schedule
        uint256 currentNumSchedules = numberOfSchedules[beneficiary];
        schedules[beneficiary][currentNumSchedules] = Schedule(
            amount,
            0,
            startTime,
            startTime + (cliffWeeks * 1 weeks),
            startTime + (vestingWeeks * 1 weeks),
            asset,
            startamount,
            isFixed
        );
        numberOfSchedules[beneficiary] = currentNumSchedules + 1;
        locked[asset] = currentLocked + amount;
        emit Vest(beneficiary, amount);
    }

    /**
     * @notice Sets up vesting schedules for multiple users within 1 transaction.
     * @dev adds a new Schedule to the schedules mapping.
     * @param accounts an array of the accounts that the vesting schedules are being set up for.
     *                 Will be able to claim tokens after the cliff period.
     * @param amount an array of the amount of tokens being vested for each user.
     * @param asset the asset that the user is being vested
     
     * @param cliffWeeks the number of weeks that the cliff will be present at.
     * @param vestingWeeks the number of weeks the tokens will vest over (linearly)
     * @param startTime the timestamp for when this vesting should have started
     */
    function multiVest(
        address[] calldata accounts,
        uint256[] calldata amount,
        address asset,
        uint256 cliffWeeks,
        uint256 vestingWeeks,
        uint256 startTime,
        uint256 startamount,
        bool isFixed
    ) external onlyOwner {
        uint256 numberOfAccounts = accounts.length;
        require(
            amount.length == numberOfAccounts,
            "Vesting: Array lengths differ"
        );
        for (uint256 i = 0; i < numberOfAccounts; i++) {
            vest(
                accounts[i],
                amount[i],
                asset,
                cliffWeeks,
                vestingWeeks,
                startTime,
                startamount,
                isFixed
            );
        }
    }

    /**
     * @notice allows users to claim vested tokens if the cliff time has passed.
     * @param scheduleNumber which schedule the user is claiming against
     */
    function claim(uint256 scheduleNumber) external {
        Schedule storage schedule = schedules[msg.sender][scheduleNumber];
        require(
            schedule.cliffTime <= block.timestamp,
            "Vesting: cliff not reached"
        );
        require(schedule.totalAmount > 0, "Vesting: not claimable");

        // Get the amount to be distributed
        uint256 TGEamount;
        if (schedule.claimedAmount > 0) {
            TGEamount = 0;
        } else {
            TGEamount = schedule.startamount;
        }
        uint256 amount = calcDistribution(
            schedule.totalAmount,
            block.timestamp,
            schedule.startTime,
            schedule.endTime,
            TGEamount
        );

        // Cap the amount at the total amount
        amount = amount > schedule.totalAmount ? schedule.totalAmount : amount;
        uint256 amountToTransfer = amount - schedule.claimedAmount;
        schedule.claimedAmount = amount; // set new claimed amount based off the curve
        locked[schedule.asset] = locked[schedule.asset] - amountToTransfer;
        require(
            IERC20(schedule.asset).transfer(msg.sender, amountToTransfer),
            "Vesting: transfer failed"
        );
        emit Claim(msg.sender, amount);
    }

    /**
     * @return calculates the amount of tokens to distribute to an account at any instance in time, based off some
     *         total claimable amount.
     * @param amount the total outstanding amount to be claimed for this vesting schedule.
     * @param currentTime the current timestamp.
     * @param startTime the timestamp this vesting schedule started.
     * @param endTime the timestamp this vesting schedule ends.
     */
    function calcDistribution(
        uint256 amount,
        uint256 currentTime,
        uint256 startTime,
        uint256 endTime,
        uint256 startamount
    ) public pure returns (uint256) {
        // avoid uint underflow
        if (currentTime < startTime) {
            return 0;
        }
        // if endTime < startTime, this will throw. Since endTime should never be
        // less than startTime in safe operation, this is fine.
        return
            ((amount * (currentTime - startTime)) / (endTime - startTime)) +
            startamount;
    }
     /**
     * @notice Allows a vesting schedule to be cancelled.
     * @dev Any outstanding tokens are returned to the system.
     * @param account the account of the user whos vesting schedule is being cancelled.
     */
    function rug(address account, uint256 scheduleId) external onlyOwner {
        Schedule storage schedule = schedules[account][scheduleId];
        require(!schedule.isFixed, "Vesting: Account is fixed");
        uint256 outstandingAmount = schedule.totalAmount -
            schedule.claimedAmount;
        require(outstandingAmount != 0, "Vesting: no outstanding tokens");
        schedule.totalAmount = 0;
        locked[schedule.asset] = locked[schedule.asset] - outstandingAmount;
        require(IERC20(schedule.asset).transfer(owner(), outstandingAmount), "Vesting: transfer failed");
        emit Cancelled(account);
    }

    /**
     * @notice Withdraws TCR tokens from the contract.
     * @dev blocks withdrawing locked tokens.
     */
    function withdraw(uint256 amount, address asset) external onlyOwner {
        IERC20 token = IERC20(asset);
        require(
            token.balanceOf(address(this)) - locked[asset] >= amount,
            "Vesting: Can't withdraw"
        );
        require(token.transfer(owner(), amount), "Vesting: withdraw failed");
    }
}
