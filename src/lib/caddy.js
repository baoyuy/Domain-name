"use strict";

const fs = require("fs");
const path = require("path");
const childProcess = require("child_process");
const os = require("os");

const CADDY_SITES_DIR = process.env.ONEPROXY_CADDY_SITES_DIR || "/etc/caddy/sites-enabled";
const CADDY_IMPORT_FILE = process.env.ONEPROXY_CADDY_IMPORT_FILE || "/etc/caddy/Caddyfile";

function run(command, args) {
  const result = childProcess.spawnSync(command, args, {
    stdio: "pipe",
    encoding: "utf8"
  });

  if (result.error) {
    throw result.error;
  }

  if (result.status !== 0) {
    const stderr = result.stderr ? result.stderr.trim() : "unknown error";
    throw new Error(`${command} ${args.join(" ")} failed: ${stderr}`);
  }

  return result.stdout.trim();
}

function runSafe(command, args) {
  const result = childProcess.spawnSync(command, args, {
    stdio: "pipe",
    encoding: "utf8"
  });

  if (result.error) {
    return {
      ok: false,
      code: -1,
      stdout: "",
      stderr: result.error.message
    };
  }

  return {
    ok: result.status === 0,
    code: result.status,
    stdout: (result.stdout || "").trim(),
    stderr: (result.stderr || "").trim()
  };
}

function ensureDirectory(dirPath) {
  fs.mkdirSync(dirPath, { recursive: true });
}

function ensureCaddyReady() {
  run("caddy", ["version"]);
  ensureDirectory(CADDY_SITES_DIR);

  const importLine = `import ${CADDY_SITES_DIR}/*.caddy`;
  const content = fs.existsSync(CADDY_IMPORT_FILE) ? fs.readFileSync(CADDY_IMPORT_FILE, "utf8") : "";

  if (!content.includes(importLine)) {
    const next = content.trimEnd()
      ? `${content.trimEnd()}\n\n${importLine}\n`
      : `${importLine}\n`;
    fs.writeFileSync(CADDY_IMPORT_FILE, next, "utf8");
  }

  reloadCaddy();
}

function buildSiteConfig(site) {
  return `${site.domains.join(", ")} {\n  reverse_proxy ${site.upstream}\n}\n`;
}

function getSiteFile(site) {
  return path.join(CADDY_SITES_DIR, `${site.id}.caddy`);
}

function writeSiteConfig(site) {
  fs.writeFileSync(getSiteFile(site), buildSiteConfig(site), "utf8");
  reloadCaddy();
}

function deleteSiteConfig(site) {
  const filePath = getSiteFile(site);
  if (fs.existsSync(filePath)) {
    fs.unlinkSync(filePath);
  }
  reloadCaddy();
}

function reloadCaddy() {
  run("systemctl", ["reload", "caddy"]);
}

function getServiceStatus() {
  const result = runSafe("systemctl", ["is-active", "caddy"]);
  return result.ok ? result.stdout : `inactive (${result.stderr || result.stdout || "unknown"})`;
}

function getLocalIps() {
  const interfaces = os.networkInterfaces();
  const ips = new Set(["127.0.0.1", "::1"]);

  for (const entries of Object.values(interfaces)) {
    for (const entry of entries || []) {
      if (!entry.internal && entry.address) {
        ips.add(entry.address);
      }
    }
  }

  return Array.from(ips);
}

function resolveDomain(domain) {
  const commands = [
    ["getent", ["ahosts", domain]],
    ["host", [domain]],
    ["nslookup", [domain]]
  ];

  for (const [command, args] of commands) {
    const result = runSafe(command, args);
    if (!result.ok || !result.stdout) {
      continue;
    }

    const matches = result.stdout.match(/(?:\d{1,3}\.){3}\d{1,3}|[a-f0-9:]{2,}/gi) || [];
    const unique = Array.from(new Set(matches));
    if (unique.length > 0) {
      return unique;
    }
  }

  return [];
}

function probeUpstream(upstream) {
  const result = runSafe("curl", ["-k", "-I", "-L", "--max-time", "8", upstream]);
  return {
    ok: result.ok,
    summary: result.ok ? (result.stdout.split("\n")[0] || "ok") : (result.stderr || result.stdout || "failed")
  };
}

function getCaddyVersion() {
  try {
    return run("caddy", ["version"]);
  } catch (error) {
    return `unavailable (${error.message})`;
  }
}

module.exports = {
  ensureCaddyReady,
  writeSiteConfig,
  deleteSiteConfig,
  reloadCaddy,
  getCaddyVersion
  ,
  getServiceStatus,
  getLocalIps,
  resolveDomain,
  probeUpstream
};
