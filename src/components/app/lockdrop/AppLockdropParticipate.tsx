"use client";
import { ChangeEvent, FC, useEffect, useRef, useState } from "react";
import {
  AllowanceTxButton,
  Amount,
  AmountInput,
  RadioGroup,
  RadioGroupItem,
  Rate,
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui";
import {
  useGenericErc20BalanceOf,
  useLTokenUnderlying,
  useLockdropAccountsLocks,
  usePrepareLockdropLock,
} from "@/generated";
import { useWalletClient } from "wagmi";
import { useContractAddress } from "@/hooks/useContractAddress";
import { formatUnits, parseUnits, zeroAddress } from "viem";
import clsx from "clsx";
import { twMerge } from "tailwind-merge";

interface Props extends React.HTMLAttributes<HTMLDivElement> {}

export const AppLockdropParticipate: FC<Props> = ({ className, ...props }) => {
  const { data: walletClient } = useWalletClient();

  // Retrieve addresses and balances
  const lTokenAddress = useContractAddress("LUSDC");
  const lockdropAddress = useContractAddress("ArbitrumLockdrop");
  const { data: underlyingAddress } = useLTokenUnderlying({ address: lTokenAddress! });
  const { data: underlyingBalance } = useGenericErc20BalanceOf({
    address: underlyingAddress,
    args: [walletClient?.account.address || zeroAddress],
    watch: true,
  });

  // Retrieve lock data
  const { data: lockData } = useLockdropAccountsLocks({
    address: lockdropAddress!,
    args: [walletClient?.account.address || zeroAddress],
    watch: true,
  });
  const hasLocked = lockData && lockData[0] !== 0n;
  const currentLockedAmount = hasLocked ? lockData[0] : 0n;
  const currentLockDuration = hasLocked ? lockData[1] : 0;

  // Retrieve input data and prepare transaction
  const inputEl = useRef<HTMLInputElement>(null);
  const [hasUserInteracted, setHasUserInteracted] = useState(false);
  const [depositedAmount, setDepositedAmount] = useState(parseUnits("100", 6));
  const [lockDuration, setLockDuration] = useState(12);
  const preparation = usePrepareLockdropLock({
    address: lockdropAddress!,
    args: [depositedAmount - currentLockedAmount, lockDuration],
  });

  // Default locked amount and duration to current ones when available
  useEffect(() => {
    if (hasLocked) {
      setDepositedAmount(currentLockedAmount);
      setLockDuration(currentLockDuration);
    }
  }, [lockData]);

  // Ensure deposited amount is always at least equal to currently deposited amount
  const timeout = useRef<NodeJS.Timeout>();
  useEffect(() => {
    if (timeout.current) clearTimeout(timeout.current);
    timeout.current = setTimeout(() => {
      if (depositedAmount < currentLockedAmount) setDepositedAmount(currentLockedAmount);
    }, 700);
  }, [depositedAmount, currentLockedAmount]);

  // Compute received LDY amount and % of allocation
  const maxWeight = parseUnits((5_000_000 * 12).toString(), 6);
  const weight = depositedAmount * BigInt(lockDuration);
  const distributedLDY = parseUnits((1_500_000).toString(), 18);
  let receivedLDY = (distributedLDY * weight) / maxWeight;
  let receivedAllocation = (Number(receivedLDY) / Number(distributedLDY)) * 100;

  // Cap received LDY and allocation to max
  if (receivedAllocation > 100) receivedAllocation = 100;
  if (receivedLDY > distributedLDY) receivedLDY = distributedLDY;

  // Figure parent error
  let isParentError = false;
  let parentError = "";
  // - Display error if not connected to Arbitrum network
  if (walletClient && ![42161, 31337].includes(walletClient.chain.id)) {
    isParentError = true;
    parentError = "Please switch to Arbitrum network";
  }
  // - Display error if trying to lock more than hardcap
  else if (depositedAmount > parseUnits((5_000_000).toString(), 6)) {
    isParentError = true;
    parentError = "Lockdrop is capped to 5M USDC";
  }

  return (
    <div className={twMerge(" py-12  !pt-0 flex flex-col", className)} {...props}>
      {hasLocked && (
        <div className="bg-[#0472B9]/10 p-2">
          <div className="flex justify-between items-center gap-10 p-10 rounded-b-xl bg-accent md:flex-nowrap flex-wrap">
            <div className="flex flex-col gap-2">
              <h3 className="font-bold text-3xl font-heading text-[#20456c]/[75%]">Your lock</h3>
              <p className="text-[#20456c]/70 font-medium">
                You can increase your lock amount and/or duration using the below update form.
              </p>
            </div>

            <div className="flex sm:gap-12 gap-8 sm:flex-nowrap flex-wrap">
              <div className="flex flex-col items-start whitespace-nowrap">
                <Amount
                  value={currentLockedAmount}
                  decimals={6}
                  suffix="USDC"
                  displaySymbol={true}
                  className="text-[1.92rem] text-[#20456c]/90 font-heading font-bold"
                />
                <h4 className="font-bold text-sm text-[#20456c]/60">Locked amount</h4>
              </div>
              <div className="flex flex-col sm:items-end items-start whitespace-nowrap">
                <span className="text-[1.92rem] text-[#20456c]/90 font-heading font-bold">
                  {currentLockDuration}
                </span>
                <h4 className="font-bold text-sm text-[#20456c]/60">Lock duration</h4>
              </div>
            </div>
          </div>
        </div>
      )}
      <div
        className="flex justify-center gap-12  flex-wrap sm:px-12
px-8 pt-12"
        {...props}
      >
        <div className="flex flex-col justify-end gap-3">
          <div className="flex items-end sm:gap-6 gap-3">
            <p className="pb-3 text-lg font-bold text-[#20456c]">Lock duration</p>
            <RadioGroup
              value={lockDuration.toString()}
              onValueChange={(value) => setLockDuration(Number.parseInt(value))}
              className="flex items-center justify-center sm:gap-6 gap-3"
            >
              <Tooltip>
                <TooltipTrigger>
                  <RadioGroupItem
                    value="3"
                    id="3m"
                    disabled={currentLockDuration > 3}
                    className="[data-state='unchecked']]:text-red-500 flex aspect-square h-12 w-12 items-center justify-center rounded-2xl text-[#0472B9]"
                  >
                    <label htmlFor="3m" className="pointer-events-none relative font-heading">
                      <div className="absolute -top-10 left-0 right-0 flex items-center justify-center">
                        <span className="rounded-lg bg-gradient-to-tr from-[#A57164] to-[#A57164]/70 px-1.5 py-1 font-heading text-sm font-semibold leading-none text-bg">
                          x3
                        </span>
                      </div>
                      3M
                    </label>
                  </RadioGroupItem>
                </TooltipTrigger>
                <TooltipContent
                  className={clsx("font-semibold", currentLockDuration <= 3 && "hidden")}
                >
                  Duration cannot be decreased
                </TooltipContent>
              </Tooltip>
              <Tooltip>
                <TooltipTrigger>
                  <RadioGroupItem
                    value="6"
                    id="6m"
                    disabled={currentLockDuration > 6}
                    className="[data-state='unchecked']]:text-red-500 flex aspect-square h-12 w-12 items-center justify-center rounded-2xl text-[#0472B9]"
                  >
                    <label htmlFor="6m" className="pointer-events-none relative font-heading">
                      <div className="absolute -top-10 left-0 right-0 flex items-center justify-center">
                        <span className="rounded-lg bg-gradient-to-tr from-[#838996] to-[#838996]/70 px-1.5 py-1 font-heading text-sm font-semibold leading-none text-bg">
                          x6
                        </span>
                      </div>
                      6M
                    </label>
                  </RadioGroupItem>
                </TooltipTrigger>
                <TooltipContent
                  className={clsx("font-semibold", currentLockDuration <= 6 && "hidden")}
                >
                  Duration cannot be decreased
                </TooltipContent>
              </Tooltip>
              <RadioGroupItem
                value="12"
                id="12m"
                className="[data-state='unchecked']]:text-red-500 flex aspect-square h-12 w-12 items-center justify-center rounded-2xl text-[#0472B9]"
              >
                <label htmlFor="12" className="pointer-events-none relative font-heading">
                  <div className="absolute -top-10 left-0 right-0 flex items-center justify-center">
                    <span className="rounded-lg bg-gradient-to-tr from-[#DAA520] to-[#DAA520]/70  px-1.5 py-1 font-heading text-sm font-semibold leading-none text-bg">
                      x12
                    </span>
                  </div>
                  1Y
                </label>
              </RadioGroupItem>
            </RadioGroup>
          </div>
          <div className="mt-6 flex flex-nowrap items-start justify-center gap-4">
            <AmountInput
              value={formatUnits(depositedAmount, 6)}
              ref={inputEl}
              maxValue={underlyingBalance}
              maxToBottom={true}
              decimals={6}
              symbol="USDC"
              onChange={(e: ChangeEvent<HTMLInputElement>) => {
                setDepositedAmount(parseUnits(e.target.value, 6));
                if (hasUserInteracted === false) setHasUserInteracted(true);
                if (e.target.value === "") setHasUserInteracted(false);
              }}
              className="sm:w-64 w-48"
            />
            <AllowanceTxButton
              size="medium"
              // @ts-ignore
              preparation={preparation}
              token={underlyingAddress!}
              spender={lockdropAddress!}
              amount={depositedAmount - currentLockedAmount}
              disabled={
                depositedAmount - currentLockedAmount <= 0n && lockDuration === currentLockDuration
              }
              hasUserInteracted={hasUserInteracted}
              parentIsError={isParentError}
              parentError={parentError}
              allowZeroAmount={true}
              className="bg-[#0472B9] transition-colors hover:bg-[#0472B9]/90"
              transactionSummary={
                <span>
                  Lock{" "}
                  <Amount
                    value={depositedAmount}
                    decimals={6}
                    suffix="USDC"
                    displaySymbol={true}
                    className="whitespace-nowrap text-indigo-300 underline decoration-indigo-300 decoration-2 underline-offset-4"
                  />{" "}
                  during{" "}
                  <span className="whitespace-nowrap text-indigo-300 underline decoration-indigo-300 decoration-2 underline-offset-4">
                    {lockDuration} months
                  </span>{" "}
                  against{" "}
                  <Amount
                    value={receivedLDY}
                    decimals={18}
                    suffix="LDY"
                    displaySymbol={true}
                    className="whitespace-nowrap text-indigo-300 underline decoration-indigo-300 decoration-2 underline-offset-4"
                  />
                </span>
              }
            >
              {hasLocked ? "Update" : "Deposit"}
            </AllowanceTxButton>
          </div>
        </div>
        <div className=" flex flex-col items-center justify-center gap-5 rounded-3xl border border-[#28a0f0]/20 bg-[#28a0f0]/10 p-5 w-64">
          <div>
            <p className="text-center font-medium text-[#20456c]/40">You&apos;ll receive</p>
            <Amount
              value={receivedLDY}
              decimals={18}
              suffix="LDY"
              className="text-center text-3xl font-bold text-[#0472B9]"
            />
          </div>
          <hr className="w-24 border-2 border-[#20456c]/10" />
          <div>
            <p className="text-center text-2xl font-bold text-[#0472B9]/60">
              <Rate value={receivedAllocation} isUD7x3={false} highPrecision={true} />
            </p>
            <p className="text-center font-medium text-[#20456c]/40">Of total allocation</p>
          </div>
        </div>
      </div>
    </div>
  );

  // Else display locker panel
  return "locker";
};
