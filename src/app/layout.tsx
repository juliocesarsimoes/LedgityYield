"use client";
import "@/styles/globals.css";
import { Poppins, Inter } from "next/font/google";
import { type NextPage } from "next";
import Header from "@/components/Header";
import { CardsHelper } from "@/components/ui";
import { usePathname } from "next/navigation";
import Footer from "@/components/Footer";

const poppins = Poppins({
  weight: ["100", "200", "300", "400", "500", "600", "700", "800", "900"],
  style: ["italic", "normal"],
  subsets: ["latin", "latin-ext"],
  display: "swap",
  variable: "--font-poppins",
});
const inter = Inter({
  weight: ["100", "200", "300", "400", "500", "600", "700", "800", "900"],
  style: ["normal"],
  subsets: ["latin", "latin-ext"],
  display: "swap",
  variable: "--font-inter",
});

export const metadata = {
  title: "Ledgity DeFi Protocol",
  description:
    "Invest stablecoins into real world assets and earn up to 7% APY. Access low-risk & stable yield offered by real world asset directly from your wallet.",
};

interface Props {
  children: React.ReactNode;
}

const RootLayout: NextPage<Props> = ({ children }) => {
  const path = usePathname();
  return (
    <>
      <html lang="en">
        <CardsHelper />
        <body className={`${inter.variable} ${poppins.variable}`}>
          <Header />
          <main>{children}</main>
          {!path.startsWith("/app") && <Footer />}
        </body>
      </html>
    </>
  );
};

export default RootLayout;
