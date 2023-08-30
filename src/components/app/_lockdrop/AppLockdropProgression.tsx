import { FC } from "react";
import { Amount } from "@/components/ui";

interface Props extends React.HTMLAttributes<HTMLDivElement> {}

export const AppLockdropProgression: FC<Props> = ({ ...props }) => {
  const progression = 0.5;

  return (
    <div className="relative -mt-3 flex flex-col items-end gap-1" {...props}>
      <div className="relative mt-7 h-[0.9rem] w-80 rounded-md rounded-r-none border border-r-0 border-[#20456c]/20">
        <div className="absolute -right-[1px] -top-6 drop-shadow-lg">
          <div className="absolute -bottom-[1.3rem] right-0 z-10 h-8 w-0.5 rounded-full bg-[#20456c]/50"></div>
          <div className="relative z-10 h-4 w-5 rounded-sm rounded-br-none bg-[url('/assets/textures/checkboard.png')] bg-cover"></div>
        </div>
        <div
          className="relative h-full rounded-l-[0.340rem] bg-gradient-to-l from-[#0472B9] to-[#0472B9]/50 transition-[width] !duration-[1500ms]"
          style={{ width: progression * 100 + "%" }}
        >
          <div className="absolute -right-[1px] -top-7 flex animate-pulse items-center gap-2">
            <div className="absolute -bottom-[1.25rem] right-0 z-10 h-8 w-0.5  rounded-full bg-[#0472B9]"></div>
            <div className="whitespace-nowrap text-xs font-semibold text-[#20456c]/60 opacity-90">
              <Amount value={123456780009n} decimals={6} className="text-[#0472B9]" /> /{" "}
              <Amount value={5000000000000n} decimals={6} />
            </div>
            <div className="rounded-md rounded-br-none bg-[#0472B9] p-1 font-heading text-xs font-bold leading-none text-bg ">
              {(progression * 100).toFixed(0)}%
            </div>
          </div>
        </div>
      </div>
      <p className="text-sm font-semibold text-[#20456c]/70">
        Only <span className="font-bold text-[#20456c]/90">28</span> days left.
      </p>
    </div>
  );
};