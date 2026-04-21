#!/usr/bin/env node
/**
 * JWT Debug Patch Script v4
 * 
 * Instead of patching source files with require("fs") (which may not work in ESM),
 * this script creates a preload module that monkey-patches Express's response.status()
 * globally. It also patches the source files using globalThis.__jwtDiagLog instead
 * of require("fs"), which is safer for ESM contexts.
 *
 * Two-pronged approach:
 * 1. Create a preload script (/tmp/jwt-preload.cjs) that monkey-patches
 *    http.ServerResponse.prototype to intercept ALL 401 responses
 * 2. Still patch the source files, but using globalThis.__jwtDiagLog() helper
 *
 * Called from entrypoint.sh when OPENCLAW_DIAG_DUMP is enabled.
 */

const fs = require('fs');
const path = require('path');

const JWT_FILE = '/app/dist/jwt-validator-CA_DfpSU.js';
const WEBHOOK_FILE = '/app/dist/src-cE0yAYZb.js';
const DIAG_LOG = '/tmp/jwt-diag.log';
const PRELOAD_SCRIPT = '/tmp/jwt-preload.cjs';

// Initialize the log file
fs.writeFileSync(DIAG_LOG, `=== JWT Debug Log v4 started at ${new Date().toISOString()} ===\n`);

// ── Step 1: Create a preload script that intercepts ALL 401 responses ──
const preloadCode = `
// jwt-preload.cjs v7 — Loaded via NODE_OPTIONS=--require
// Enhanced interceptor: decodes JWT tokens and logs validation details on 401.
const fs = require('fs');
const DIAG_LOG = '/tmp/jwt-diag.log';

function diagLog(msg) {
  try {
    fs.appendFileSync(DIAG_LOG, '[JWT-DIAG] ' + msg + '\\n');
    // Also write to stdout immediately for Container App logs
    process.stdout.write('[JWT-DIAG] ' + msg + '\\n');
  } catch (e) {
    process.stdout.write('[JWT-DIAG] ' + msg + '\\n');
  }
}

globalThis.__jwtDiagLog = diagLog;

// Helper: decode JWT payload without verification (for logging only)
function decodeJwtPayload(token) {
  try {
    const parts = token.split('.');
    if (parts.length !== 3) return { error: 'not-3-parts' };
    const payload = Buffer.from(parts[1], 'base64').toString('utf-8');
    return JSON.parse(payload);
  } catch (e) {
    return { error: e.message };
  }
}

// Helper: decode JWT header
function decodeJwtHeader(token) {
  try {
    const parts = token.split('.');
    if (parts.length !== 3) return { error: 'not-3-parts' };
    const header = Buffer.from(parts[0], 'base64').toString('utf-8');
    return JSON.parse(header);
  } catch (e) {
    return { error: e.message };
  }
}

const http = require('http');

// ── 1. Intercept ALL HTTP responses with status 401 ──
const originalWriteHead = http.ServerResponse.prototype.writeHead;
http.ServerResponse.prototype.writeHead = function(statusCode, ...args) {
  if (statusCode === 401) {
    const stack = new Error().stack.split('\\n').slice(1, 8).join(' | ');
    diagLog('writeHead-401 stack=' + stack);
    if (this.req) {
      const authHeader = this.req.headers.authorization || '';
      const bearerToken = authHeader.startsWith('Bearer ') ? authHeader.substring(7) : '';
      
      // Decode and log the JWT token details
      if (bearerToken) {
        const header = decodeJwtHeader(bearerToken);
        const payload = decodeJwtPayload(bearerToken);
        diagLog('writeHead-401-jwt-header=' + JSON.stringify(header));
        diagLog('writeHead-401-jwt-payload=' + JSON.stringify(payload));
      }
      
      diagLog('writeHead-401 method=' + this.req.method + ' url=' + this.req.url + 
        ' auth=' + (authHeader ? authHeader.substring(0, 40) + '...' : 'none') +
        ' content-type=' + (this.req.headers['content-type'] || 'none') +
        ' host=' + (this.req.headers.host || 'none'));
      
      // Log the request body if available (Express parsed body)
      if (this.req.body) {
        try {
          const bodyStr = JSON.stringify(this.req.body);
          diagLog('writeHead-401-body=' + bodyStr.substring(0, 500));
        } catch(e) {}
      }
    }
  }
  return originalWriteHead.call(this, statusCode, ...args);
};

// ── 2. Intercept ALL incoming HTTP requests at the server level ──
const originalEmit = http.Server.prototype.emit;
http.Server.prototype.emit = function(event, ...args) {
  if (event === 'request' && args[0]) {
    const req = args[0];
    const addr = this.address();
    const port = addr && addr.port ? addr.port : 'unknown';
    const authHeader = req.headers.authorization || '';
    diagLog('http-request port=' + port + ' method=' + req.method + ' url=' + req.url +
      ' auth=' + (authHeader ? authHeader.substring(0, 40) + '...' : 'none'));
  }
  return originalEmit.call(this, event, ...args);
};

// ── 3. Track server.listen() calls to see what ports are opened ──
const originalListen = http.Server.prototype.listen;
http.Server.prototype.listen = function(...args) {
  const port = typeof args[0] === 'number' ? args[0] : (typeof args[0] === 'object' ? args[0].port : 'unknown');
  const stack = new Error().stack.split('\\n').slice(1, 5).join(' | ');
  diagLog('server-listen port=' + port + ' stack=' + stack);
  return originalListen.apply(this, args);
};

// ── 4. Also patch http2 if loaded ──
try {
  const http2 = require('http2');
  if (http2.Http2ServerResponse) {
    const orig2 = http2.Http2ServerResponse.prototype.writeHead;
    http2.Http2ServerResponse.prototype.writeHead = function(statusCode, ...args) {
      if (statusCode === 401) {
        const stack = new Error().stack.split('\\n').slice(1, 8).join(' | ');
        diagLog('http2-writeHead-401 stack=' + stack);
      }
      return orig2.call(this, statusCode, ...args);
    };
    diagLog('preload-active: http2.Http2ServerResponse.writeHead patched');
  }
} catch (e) {
  diagLog('http2 patch skipped: ' + e.message);
}

// ── 5. Log environment variables related to MSTeams auth ──
const envKeys = ['MicrosoftAppId', 'MicrosoftAppType', 'MicrosoftAppTenantId',
  'MSTEAMS_APP_ID', 'MSTEAMS_APP_TYPE', 'MSTEAMS_TENANT_ID'];
for (const key of envKeys) {
  if (process.env[key]) {
    diagLog('env ' + key + '=' + process.env[key]);
  }
}

diagLog('preload-active: v8 with JWT decode, env dump, body logging, JWKS connectivity test');

// ── 6. Test JWKS endpoint connectivity on startup ──
// This is the most likely failure point: if the container cannot reach the
// JWKS endpoints, both JWT validators will throw and silently fail.
(async function testJwksConnectivity() {
  const https = require('https');
  const jwksUrls = [
    'https://login.botframework.com/v1/.well-known/keys',
    'https://login.microsoftonline.com/common/discovery/v2.0/keys',
    'https://login.microsoftonline.com/92e3f433-65c8-460d-9a27-e252a02d1b4f/discovery/v2.0/keys',
  ];
  
  for (const url of jwksUrls) {
    try {
      const result = await new Promise((resolve, reject) => {
        const startTime = Date.now();
        const req = https.get(url, { timeout: 10000 }, (res) => {
          let body = '';
          res.on('data', (chunk) => body += chunk);
          res.on('end', () => {
            const elapsed = Date.now() - startTime;
            resolve({ status: res.statusCode, elapsed, bodyLen: body.length, keysCount: 'n/a' });
            try {
              const parsed = JSON.parse(body);
              resolve({ status: res.statusCode, elapsed, bodyLen: body.length, keysCount: (parsed.keys || []).length });
            } catch(e) {
              resolve({ status: res.statusCode, elapsed, bodyLen: body.length, keysCount: 'parse-error' });
            }
          });
        });
        req.on('error', (err) => {
          const elapsed = Date.now() - startTime;
          reject({ error: err.message, code: err.code, elapsed });
        });
        req.on('timeout', () => {
          req.destroy();
          const elapsed = Date.now() - startTime;
          reject({ error: 'timeout', elapsed });
        });
      });
      diagLog('JWKS-TEST OK url=' + url + ' status=' + result.status + ' keys=' + result.keysCount + ' elapsed=' + result.elapsed + 'ms bodyLen=' + result.bodyLen);
    } catch (e) {
      diagLog('JWKS-TEST FAIL url=' + url + ' error=' + (e.error || e.message || JSON.stringify(e)) + ' code=' + (e.code || 'none') + ' elapsed=' + (e.elapsed || 'n/a') + 'ms');
    }
  }
  diagLog('JWKS-TEST all connectivity tests complete');
})();
`;

fs.writeFileSync(PRELOAD_SCRIPT, preloadCode);
console.log('Created preload script at ' + PRELOAD_SCRIPT);

// ── Step 2: Patch source files for diagnostic logging ──

const CHANNEL_FILE = '/app/dist/channel-04y1k7xQ.js';

function patchCatchBlocks(filePath, prefix) {
  if (!fs.existsSync(filePath)) {
    console.log('WARN: ' + filePath + ' not found');
    return;
  }

  console.log('Patching catch blocks in ' + filePath + ' ...');
  let code = fs.readFileSync(filePath, 'utf-8');
  const origLen = code.length;
  let patches = 0;

  const catchRegex = /\bcatch\s*\((\w+)\)\s*\{/g;
  const catchPositions = [];
  let match;
  while ((match = catchRegex.exec(code)) !== null) {
    catchPositions.push({
      index: match.index,
      fullMatch: match[0],
      varName: match[1],
      endIndex: match.index + match[0].length
    });
  }

  for (let i = catchPositions.length - 1; i >= 0; i--) {
    const pos = catchPositions[i];
    const v = pos.varName;
    const logStmt = 'globalThis.__jwtDiagLog&&globalThis.__jwtDiagLog("' + prefix + '-catch-' + (i + 1) +
      ' " + (' + v + '&&' + v + '.message||String(' + v + ')));';
    code = code.substring(0, pos.endIndex) + logStmt + code.substring(pos.endIndex);
    patches++;
  }

  fs.writeFileSync(filePath, code);
  console.log(prefix + ': ' + patches + ' catch blocks patched (' + origLen + ' -> ' + code.length + ' bytes)');
}

function patchValidateMethod() {
  // Patch the channel file which contains createBotFrameworkJwtValidator.
  // The validate method returns a boolean. We need to log what it returns.
  // Strategy: find ".validate(" and wrap the result with logging.
  
  // Also try to find and patch the JwtValidator.validate method in jwt-validator file
  for (const fp of [JWT_FILE, CHANNEL_FILE]) {
    if (!fs.existsSync(fp)) {
      console.log('WARN: ' + fp + ' not found for validate patch');
      continue;
    }
    let code = fs.readFileSync(fp, 'utf-8');
    const origLen = code.length;
    let patches = 0;
    
    // Find all ".validate(" calls and add logging before/after
    // Look for pattern: .validate(authHeader or similar
    const validateRegex = /\.validate\s*\(/g;
    let vMatch;
    const positions = [];
    while ((vMatch = validateRegex.exec(code)) !== null) {
      positions.push(vMatch.index);
    }
    
    console.log(fp + ': found ' + positions.length + ' .validate() calls');
    
    // Find "return" statements near "validate" — these are in the validator class
    // Look for patterns like: return true/false near validate
    // Instead, let's look for the validate function definition
    const validateDefRegex = /async\s+validate\s*\(/g;
    const defPositions = [];
    while ((vMatch = validateDefRegex.exec(code)) !== null) {
      defPositions.push({ index: vMatch.index, match: vMatch[0] });
    }
    
    console.log(fp + ': found ' + defPositions.length + ' async validate() definitions');
    
    // For each definition, find the { after it and inject logging
    for (let i = defPositions.length - 1; i >= 0; i--) {
      const pos = defPositions[i];
      // Find the opening brace
      const braceIdx = code.indexOf('{', pos.index + pos.match.length);
      if (braceIdx >= 0 && braceIdx < pos.index + 200) {
        const logStmt = 'globalThis.__jwtDiagLog&&globalThis.__jwtDiagLog("validate-entry args=" + JSON.stringify([...arguments].map((a,i)=>i===0?(typeof a==="string"?a.substring(0,40)+"...":typeof a):a)));';
        code = code.substring(0, braceIdx + 1) + logStmt + code.substring(braceIdx + 1);
        patches++;
      }
    }
    
    // Also find "return true" and "return false" near validate context
    // Add logging before return statements
    const returnRegex = /return\s+(true|false)\s*;/g;
    const returnPositions = [];
    while ((vMatch = returnRegex.exec(code)) !== null) {
      returnPositions.push({ index: vMatch.index, value: vMatch[1], length: vMatch[0].length });
    }
    
    for (let i = returnPositions.length - 1; i >= 0; i--) {
      const pos = returnPositions[i];
      const logStmt = 'globalThis.__jwtDiagLog&&globalThis.__jwtDiagLog("validate-return=' + pos.value + '");';
      code = code.substring(0, pos.index) + logStmt + code.substring(pos.index);
      patches++;
    }
    
    if (patches > 0) {
      fs.writeFileSync(fp, code);
      console.log(fp + ': ' + patches + ' validate-related patches (' + origLen + ' -> ' + code.length + ' bytes)');
    }
  }
}

// Start debug HTTP server (reachable only from inside the container)
function startDebugServer() {
  try {
    const http = require('http');
    const server = http.createServer((req, res) => {
      if (req.url === '/diag' || req.url === '/') {
        try {
          const logContent = fs.readFileSync(DIAG_LOG, 'utf-8');
          res.writeHead(200, {'Content-Type': 'text/plain'});
          res.end(logContent);
        } catch (e) {
          res.writeHead(200, {'Content-Type': 'text/plain'});
          res.end('No diag log yet: ' + e.message);
        }
      } else {
        res.writeHead(200, {'Content-Type': 'text/plain'});
        res.end('JWT Debug Server v4\nGET /diag - diagnostic log\n');
      }
    });
    server.listen(9999, '0.0.0.0', () => {
      console.log('[jwt-debug-server] listening on port 9999');
    });
    server.unref();
  } catch (e) {
    console.error('Failed to start debug server:', e.message);
  }
}

try {
  patchCatchBlocks(JWT_FILE, 'jwt');
} catch (e) {
  console.error('JWT validator patch error:', e.message);
}

try {
  patchCatchBlocks(WEBHOOK_FILE, 'webhook');
} catch (e) {
  console.error('Webhook middleware patch error:', e.message);
}

try {
  patchCatchBlocks(CHANNEL_FILE, 'channel');
} catch (e) {
  console.error('Channel file patch error:', e.message);
}

try {
  patchValidateMethod();
} catch (e) {
  console.error('Validate method patch error:', e.message);
}

startDebugServer();

// ── Dump msteams source files LINE BY LINE for Log Analytics (v7) ──
function dumpMSTeamsFiles() {
  // Critical files to dump fully, one line at a time (avoids Log Analytics truncation)
  const criticalFiles = [
    '/app/extensions/msteams/src/sdk.ts',
    '/app/extensions/msteams/src/token.ts',
  ];
  
  for (const fp of criticalFiles) {
    if (!fs.existsSync(fp)) {
      console.log('SRC-DUMP NOT FOUND: ' + fp);
      continue;
    }
    try {
      const content = fs.readFileSync(fp, 'utf-8');
      const lines = content.split('\n');
      const shortName = fp.replace('/app/extensions/msteams/src/', '');
      console.log('SRC-DUMP-START ' + shortName + ' lines=' + lines.length);
      for (let i = 0; i < lines.length; i++) {
        console.log('SRC:' + shortName + ':' + (i + 1) + ':' + lines[i].substring(0, 400));
      }
      console.log('SRC-DUMP-END ' + shortName);
    } catch(e) {
      console.log('SRC-DUMP ERROR ' + fp + ': ' + e.message);
    }
  }
}

try {
  dumpMSTeamsFiles();
} catch (e) {
  console.error('MSTeams file dump error:', e.message);
}

console.log('JWT debug patch v7 complete.');
