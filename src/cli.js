#!/usr/bin/env node

const { runCli } = require("./lib/app");

runCli().catch((error) => {
  console.error(`\n[oneproxy] ${error.message}`);
  process.exit(1);
});
