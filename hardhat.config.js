require("@nomicfoundation/hardhat-toolbox");

module.exports = {
  solidity: {
    compilers: [
      {
        version: "0.8.20", // Add this version
      },
      {
        version: "0.8.19", // Keep this if you have contracts requiring 0.8.19
      },
    ],
  },
};
