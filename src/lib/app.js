"use strict";

const os = require("os");
const fs = require("fs");
const path = require("path");
const readline = require("readline/promises");
const { stdin, stdout } = require("process");
const {
  ensureCaddyReady,
  writeSiteConfig,
  deleteSiteConfig,
  reloadCaddy,
  getCaddyVersion,
  getServiceStatus,
  getLocalIps,
  resolveDomain,
  probeUpstream
} = require("./caddy");
const { loadStore, saveStore } = require("./store");

function createInterface() {
  return readline.createInterface({
    input: stdin,
    output: stdout
  });
}

function isRoot() {
  return typeof process.getuid === "function" ? process.getuid() === 0 : false;
}

function printHeader() {
  console.log("=== oneproxy ===");
  console.log("命令行反代管理工具，底层使用 Caddy\n");
}

function printMenu() {
  console.log("1. 新增反代");
  console.log("2. 查看站点");
  console.log("3. 修改站点");
  console.log("4. 删除站点");
  console.log("5. 批量导入");
  console.log("6. 重载 Caddy");
  console.log("7. 环境诊断");
  console.log("8. 站点诊断");
  console.log("9. 帮助");
  console.log("0. 退出\n");
}

async function promptNonEmpty(rl, label, fallback = "") {
  while (true) {
    const suffix = fallback ? ` [${fallback}]` : "";
    const answer = (await rl.question(`${label}${suffix}: `)).trim();
    const value = answer || fallback;
    if (value) {
      return value;
    }
    console.log("输入不能为空。\n");
  }
}

async function promptOptional(rl, label, fallback = "") {
  const suffix = fallback ? ` [${fallback}]` : "";
  const answer = (await rl.question(`${label}${suffix}: `)).trim();
  return answer || fallback;
}

async function promptYesNo(rl, label, defaultYes = true) {
  const suffix = defaultYes ? " [Y/n]" : " [y/N]";
  const answer = (await rl.question(`${label}${suffix}: `)).trim().toLowerCase();
  if (!answer) {
    return defaultYes;
  }
  return answer === "y" || answer === "yes";
}

function normalizeUpstream(upstream) {
  if (/^https?:\/\//i.test(upstream)) {
    return upstream;
  }
  return `http://${upstream}`;
}

function normalizeDomains(input) {
  return Array.from(
    new Set(
      input
        .split(",")
        .map((item) => item.trim().toLowerCase())
        .filter(Boolean)
    )
  );
}

function buildId(domain) {
  return domain.replace(/[^a-z0-9.-]/g, "-");
}

function validateSiteInput(domains, upstream) {
  if (domains.length === 0) {
    throw new Error("没有识别到有效域名。");
  }
  if (!upstream) {
    throw new Error("源站地址不能为空。");
  }
}

function renderSite(site) {
  console.log(`- ${site.id}`);
  console.log(`  域名    : ${site.domains.join(", ")}`);
  console.log(`  源站    : ${site.upstream}`);
  console.log(`  创建时间: ${site.createdAt}`);
  if (site.updatedAt) {
    console.log(`  更新时间: ${site.updatedAt}`);
  }
}

function formatCheck(ok) {
  return ok ? "正常" : "异常";
}

function analyzeDomain(domain) {
  const resolvedIps = resolveDomain(domain);
  const localIps = getLocalIps();
  const matched = resolvedIps.filter((ip) => localIps.includes(ip));

  return {
    domain,
    resolvedIps,
    localIps,
    matched,
    ok: matched.length > 0
  };
}

function printDomainChecks(domains) {
  console.log("\n域名解析检查");
  for (const domain of domains) {
    const result = analyzeDomain(domain);
    console.log(`- ${domain}: ${formatCheck(result.ok)}`);
    console.log(`  解析结果: ${result.resolvedIps.length > 0 ? result.resolvedIps.join(", ") : "未解析到 IP"}`);
    console.log(`  本机 IP : ${result.localIps.join(", ")}`);
    if (!result.ok) {
      console.log("  建议    : 先把域名 A/AAAA 记录解析到这台服务器，再申请 HTTPS。");
    }
  }
}

function printUpstreamCheck(upstream) {
  const result = probeUpstream(upstream);
  console.log("\n源站连通性检查");
  console.log(`- 状态: ${formatCheck(result.ok)}`);
  console.log(`  结果: ${result.summary}`);
  if (!result.ok) {
    console.log("  建议: 确认源站端口已监听、防火墙已放行、协议 http/https 填写正确。");
  }
}

function printPostSaveSummary(site, actionLabel) {
  console.log(`\n站点已${actionLabel}。`);
  console.log(`站点 ID : ${site.id}`);
  console.log(`反代域名: ${site.domains.join(", ")}`);
  console.log(`源站地址: ${site.upstream}`);
  printDomainChecks(site.domains);
  printUpstreamCheck(site.upstream);
  console.log("\nCaddy 配置已写入并重载。\n");
}

function listSites(store) {
  console.log("");
  if (store.sites.length === 0) {
    console.log("当前没有已配置站点。\n");
    return;
  }

  for (const site of store.sites) {
    renderSite(site);
    console.log("");
  }
}

function findSite(store, id) {
  return store.sites.find((site) => site.id === id);
}

function findSiteIndex(store, id) {
  return store.sites.findIndex((site) => site.id === id);
}

function saveSite(store, site, oldSite = null) {
  if (oldSite) {
    deleteSiteConfig(oldSite);
    const index = findSiteIndex(store, oldSite.id);
    store.sites[index] = site;
  } else {
    store.sites.push(site);
  }

  writeSiteConfig(site);
  saveStore(store);
}

async function collectSiteInput(rl, defaults = {}) {
  const domainInput = await promptNonEmpty(rl, "请输入域名，多个域名用英文逗号分隔", (defaults.domains || []).join(", "));
  const upstreamInput = await promptNonEmpty(rl, "请输入源站地址", defaults.upstream || "127.0.0.1:3000");
  const domains = normalizeDomains(domainInput);
  const upstream = normalizeUpstream(upstreamInput);
  validateSiteInput(domains, upstream);

  return {
    domains,
    upstream
  };
}

async function addSite(rl, store) {
  console.log("\n新增反代\n");
  const input = await collectSiteInput(rl);
  const id = buildId(input.domains[0]);

  if (findSite(store, id)) {
    throw new Error(`站点 "${id}" 已存在。`);
  }

  const site = {
    id,
    domains: input.domains,
    upstream: input.upstream,
    createdAt: new Date().toISOString()
  };

  saveSite(store, site);
  printPostSaveSummary(site, "新增");
}

async function editSite(rl, store) {
  console.log("\n修改站点\n");
  if (store.sites.length === 0) {
    console.log("当前没有已配置站点。\n");
    return;
  }

  listSites(store);
  const id = await promptNonEmpty(rl, "请输入要修改的站点 ID");
  const oldSite = findSite(store, id);
  if (!oldSite) {
    throw new Error(`未找到站点 "${id}"。`);
  }

  const input = await collectSiteInput(rl, oldSite);
  const nextId = buildId(input.domains[0]);
  if (nextId !== oldSite.id && findSite(store, nextId)) {
    throw new Error(`目标站点 ID "${nextId}" 已存在。`);
  }

  const site = {
    ...oldSite,
    id: nextId,
    domains: input.domains,
    upstream: input.upstream,
    updatedAt: new Date().toISOString()
  };

  saveSite(store, site, oldSite);
  printPostSaveSummary(site, "修改");
}

async function removeSite(rl, store) {
  console.log("\n删除站点\n");
  if (store.sites.length === 0) {
    console.log("当前没有已配置站点。\n");
    return;
  }

  listSites(store);
  const id = await promptNonEmpty(rl, "请输入要删除的站点 ID");
  const siteIndex = findSiteIndex(store, id);
  if (siteIndex === -1) {
    throw new Error(`未找到站点 "${id}"。`);
  }

  const confirmed = await promptYesNo(rl, `确认删除站点 "${id}" 吗`, false);
  if (!confirmed) {
    console.log("\n已取消删除。\n");
    return;
  }

  deleteSiteConfig(store.sites[siteIndex]);
  store.sites.splice(siteIndex, 1);
  saveStore(store);

  console.log(`\n站点 "${id}" 已删除。\n`);
}

function parseBatchLine(line) {
  const trimmed = line.trim();
  if (!trimmed || trimmed.startsWith("#")) {
    return null;
  }

  const parts = trimmed.split(/\s*=>\s*|\s+\|\s+|\s+/).filter(Boolean);
  if (parts.length < 2) {
    throw new Error(`无法解析导入行: ${line}`);
  }

  return {
    domains: normalizeDomains(parts[0]),
    upstream: normalizeUpstream(parts[1])
  };
}

async function importSites(rl, store) {
  console.log("\n批量导入\n");
  console.log("文件格式示例:");
  console.log("example.com 127.0.0.1:3000");
  console.log("a.com,b.com => http://127.0.0.1:4000\n");

  const filePath = await promptNonEmpty(rl, "请输入导入文件路径");
  const fullPath = path.resolve(filePath);
  if (!fs.existsSync(fullPath)) {
    throw new Error(`文件不存在: ${fullPath}`);
  }

  const lines = fs.readFileSync(fullPath, "utf8").split(/\r?\n/);
  let created = 0;
  let updated = 0;

  for (const line of lines) {
    const parsed = parseBatchLine(line);
    if (!parsed) {
      continue;
    }

    validateSiteInput(parsed.domains, parsed.upstream);
    const id = buildId(parsed.domains[0]);
    const existing = findSite(store, id);
    const site = existing
      ? {
          ...existing,
          domains: parsed.domains,
          upstream: parsed.upstream,
          updatedAt: new Date().toISOString()
        }
      : {
          id,
          domains: parsed.domains,
          upstream: parsed.upstream,
          createdAt: new Date().toISOString()
        };

    saveSite(store, site, existing);
    if (existing) {
      updated += 1;
    } else {
      created += 1;
    }
  }

  console.log(`\n批量导入完成。新增 ${created} 个，更新 ${updated} 个。\n`);
}

async function doctor() {
  console.log("\n环境诊断\n");
  console.log(`系统平台 : ${os.platform()}`);
  console.log(`Node 版本: ${process.version}`);
  console.log(`Root 权限: ${isRoot() ? "是" : "否"}`);
  console.log(`Caddy 版本: ${getCaddyVersion()}`);
  console.log(`Caddy 状态: ${getServiceStatus()}`);
  console.log(`本机 IP   : ${getLocalIps().join(", ")}`);
  console.log("");
}

async function siteDoctor(rl, store) {
  console.log("\n站点诊断\n");
  if (store.sites.length === 0) {
    console.log("当前没有已配置站点。\n");
    return;
  }

  listSites(store);
  const id = await promptNonEmpty(rl, "请输入要诊断的站点 ID");
  const site = findSite(store, id);
  if (!site) {
    throw new Error(`未找到站点 "${id}"。`);
  }

  console.log(`\n诊断站点: ${site.id}`);
  printDomainChecks(site.domains);
  printUpstreamCheck(site.upstream);
  console.log(`\nCaddy 状态: ${getServiceStatus()}\n`);
}

function printHelp() {
  console.log("\n帮助\n");
  console.log("- 新增反代: 输入域名和源站，自动生成 Caddy 配置。");
  console.log("- 修改站点: 可修改域名和源站，首个域名会作为站点 ID。");
  console.log("- 批量导入: 从文本文件批量创建或更新站点。");
  console.log("- 环境诊断: 检查 Node、Caddy、服务状态、本机 IP。");
  console.log("- 站点诊断: 检查域名解析和源站连通性。");
  console.log("- 卸载项目: 运行 uninstall.sh 可移除 oneproxy 及其数据。\n");
}

async function runCli() {
  if (!isRoot()) {
    throw new Error("请使用 sudo 或 root 运行，因为需要写入 Caddy 配置。");
  }

  ensureCaddyReady();
  const store = loadStore();
  const rl = createInterface();

  try {
    printHeader();

    while (true) {
      printMenu();
      const choice = (await rl.question("请选择功能: ")).trim();

      if (choice === "0") {
        console.log("\n已退出。");
        return;
      }

      if (choice === "1") {
        await addSite(rl, store);
        continue;
      }

      if (choice === "2") {
        listSites(store);
        continue;
      }

      if (choice === "3") {
        await editSite(rl, store);
        continue;
      }

      if (choice === "4") {
        await removeSite(rl, store);
        continue;
      }

      if (choice === "5") {
        await importSites(rl, store);
        continue;
      }

      if (choice === "6") {
        reloadCaddy();
        console.log("\nCaddy 已重载。\n");
        continue;
      }

      if (choice === "7") {
        await doctor();
        continue;
      }

      if (choice === "8") {
        await siteDoctor(rl, store);
        continue;
      }

      if (choice === "9") {
        printHelp();
        continue;
      }

      console.log("\n无效选项。\n");
    }
  } finally {
    rl.close();
  }
}

module.exports = {
  runCli
};
