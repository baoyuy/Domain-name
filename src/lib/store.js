"use strict";

const fs = require("fs");
const path = require("path");

const DATA_DIR = process.env.ONEPROXY_DATA_DIR || "/opt/oneproxy/data";
const STORE_FILE = path.join(DATA_DIR, "sites.json");

function ensureDataDir() {
  fs.mkdirSync(DATA_DIR, { recursive: true });
}

function loadStore() {
  ensureDataDir();

  if (!fs.existsSync(STORE_FILE)) {
    return { sites: [] };
  }

  const raw = fs.readFileSync(STORE_FILE, "utf8");
  return JSON.parse(raw);
}

function saveStore(store) {
  ensureDataDir();
  fs.writeFileSync(STORE_FILE, JSON.stringify(store, null, 2) + "\n", "utf8");
}

module.exports = {
  loadStore,
  saveStore
};
