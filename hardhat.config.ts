import '@eth-optimism/plugins/hardhat/compiler'

const config = {
  networks: {
    hardhat: {
      accounts: {
        mnemonic: 'test test test test test test test test test test test junk',
      },
    },
  },
  solidity: '0.6.12',
  ovm: {
    solcVersion: '0.6.12',
  },
  namedAccounts: {
    deployer: 0,
  },
  mocha: {
    timeout: 20000,
  },
}

export default config
