const http = require('http');
const fs = require('fs');
const os = require('os');

const PORT = 8080;
const HOST = '0.0.0.0';
const MAX_BODY_SIZE = 256 * 1024;
const RATE_LIMIT_WINDOW_MS = 1000;
const RATE_LIMIT_MAX_REQUESTS = 10;

const MAX_UPDATES = 200;
const MAX_BUILT_IN_EVENTS = 500;
const MAX_DISPLAY_EVENTS = 50;
const PROGRESS_MIN = 0;
const PROGRESS_MAX = 100;
const STALL_WARNING_MS = 5 * 60 * 1000;
const STALL_ERROR_MS = 15 * 60 * 1000;

const rateLimitMap = new Map();

// Progress data
let data = {
    startTime: null,
    prepStartTime: null,
    lastUpdate: null,
    progress: 0,
    stage: 0,
    phase: 'waiting',
    status: 'waiting',
    message: 'Waiting for installation to start...',
    ip: null,
    hostname: null,
    username: null,
    wifi_ssid: null,
    updates: [],
    builtInEvents: [],
    stalled: false,
    stalledSince: null
};

// Escape HTML to prevent XSS
function escapeHtml(str) {
    if (!str) return '';
    return String(str)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#039;');
}

// Get network IPs
function getIPs() {
    const interfaces = os.networkInterfaces();
    const ips = [];
    for (const name of Object.keys(interfaces)) {
        for (const iface of interfaces[name]) {
            if (iface.family === 'IPv4' && !iface.internal) {
                ips.push(iface.address);
            }
        }
    }
    return ips;
}

// Save progress
function save() {
    try {
        const dir = './logs';
        if (!fs.existsSync(dir)) fs.mkdirSync(dir);
        fs.writeFileSync(`${dir}/progress.json`, JSON.stringify(data, null, 2));
    } catch (e) {
        console.error('Warning: Failed to save progress:', e.message);
    }
}

// Load progress
function load() {
    try {
        if (fs.existsSync('./logs/progress.json')) {
            const loaded = JSON.parse(fs.readFileSync('./logs/progress.json', 'utf8'));
            data = { ...data, ...loaded };
            if (data.updates && data.updates.length > MAX_UPDATES) {
                data.updates = data.updates.slice(-MAX_UPDATES);
            }
            if (data.builtInEvents && data.builtInEvents.length > MAX_BUILT_IN_EVENTS) {
                data.builtInEvents = data.builtInEvents.slice(-MAX_BUILT_IN_EVENTS);
            }
        }
    } catch (e) {
        console.log('No previous progress data found');
    }
}

// Check for stalled installation
function checkStalled() {
    if (!data.lastUpdate || data.phase === 'waiting') {
        return;
    }
    
    const elapsed = Date.now() - new Date(data.lastUpdate).getTime();
    
    if (elapsed >= STALL_ERROR_MS) {
        if (!data.stalled) {
            data.stalled = true;
            data.stalledSince = new Date().toISOString();
            console.log('\n[STALL DETECTED] No update for', Math.floor(elapsed/60000), 'minutes');
            save();
        }
    } else if (elapsed >= STALL_WARNING_MS) {
        const mins = Math.floor(elapsed / 60000);
        console.log('[WARNING]', mins, 'minutes since last update');
    }
}

// Format built-in event name for display
function formatEventName(name) {
    if (!name) return 'Unknown';
    const parts = name.split('/');
    if (parts.length >= 2) {
        const module = parts[parts.length - 2];
        const action = parts[parts.length - 1].replace(/^_/, '');
        return `${module}: ${action}`;
    }
    return name;
}

// Get color for event level
function getLevelColor(level) {
    switch (level) {
        case 'ERROR': return '#dc3545';
        case 'WARNING': return '#ffc107';
        case 'WARN': return '#ffc107';
        case 'INFO': return '#17a2b8';
        case 'DEBUG': return '#6c757d';
        default: return '#6c757d';
    }
}

// Get color for result
function getResultColor(result) {
    switch (result) {
        case 'SUCCESS': return '#28a745';
        case 'FAILURE': return '#dc3545';
        case 'WARN': return '#ffc107';
        default: return '#6c757d';
    }
}

function getStageColor(stage) {
    if (!stage) return '#6c757d';
    if (stage.startsWith('prep') || stage === 'early-init') return '#17a2b8';
    if (stage.startsWith('late')) return '#28a745';
    if (stage === 'complete' || stage === 'done') return '#28a745';
    if (stage === 'error') return '#dc3545';
    return '#6c757d';
}

function getStatusIcon(status) {
    switch (status) {
        case 'running': return '&#9654;';
        case 'installing': return '&#9654;';
        case 'building': return '&#9881;';
        case 'loaded': return '&#10003;';
        case 'online': return '&#10003;';
        case 'ready': return '&#10003;';
        case 'configured': return '&#10003;';
        case 'pinned': return '&#128278;';
        case 'installed': return '&#10003;';
        case 'done': return '&#10003;';
        case 'complete': return '&#10003;';
        case 'detecting': return '&#128269;';
        case 'starting': return '&#9654;';
        case 'saving': return '&#128190;';
        case 'warning': return '&#9888;';
        case 'failed': return '&#10060;';
        default: return '&#9679;';
    }
}

// Generate HTML
function html() {
    const pct = data.progress;
    const color = pct < 50 ? '#ffc107' : pct < 90 ? '#17a2b8' : '#28a745';
    
    const isPrep = data.phase === 'prep';
    const isInstall = data.phase === 'install';
    
    let elapsed = 0;
    if (isPrep && data.prepStartTime) {
        elapsed = Math.floor((Date.now() - new Date(data.prepStartTime)) / 1000);
    } else if (data.startTime) {
        elapsed = Math.floor((Date.now() - new Date(data.startTime)) / 1000);
    }
    const mins = Math.floor(elapsed / 60);
    const secs = elapsed % 60;
    
    const stageLabel = isPrep ? 'Preparation' : isInstall ? 'Installation' : 'Waiting';
    const totalStages = isPrep ? 10 : 7;
    const currentStage = isPrep ? Math.ceil(pct / 10) : data.stage;
    
    checkStalled();
    
    let stallWarning = '';
    if (data.stalled && data.lastUpdate) {
        const stallTime = Math.floor((Date.now() - new Date(data.lastUpdate).getTime()) / 60000);
        stallWarning = '<div style="background:#dc3545;color:white;padding:20px;border-radius:8px;margin:20px 0"><strong>&#9888; STALLED INSTALLATION</strong><br>No update for ' + stallTime + ' minutes. Check Mac Pro status.</div>';
    } else if (data.lastUpdate && data.phase !== 'waiting') {
        const elapsed2 = Date.now() - new Date(data.lastUpdate).getTime();
        if (elapsed2 >= STALL_WARNING_MS && elapsed2 < STALL_ERROR_MS) {
            const warnMins = Math.floor(elapsed2 / 60000);
            stallWarning = '<div style="background:#ffc107;color:black;padding:15px;border-radius:8px;margin:20px 0"><strong>&#9888; Warning:</strong> ' + warnMins + ' minutes since last update</div>';
        }
    }
    
    let builtInHtml = '';
    if (data.builtInEvents && data.builtInEvents.length > 0) {
        const recentEvents = data.builtInEvents.slice(-MAX_DISPLAY_EVENTS).reverse();
        builtInHtml = recentEvents.map(e => {
            const time = e.timestamp ? new Date(e.timestamp * 1000).toLocaleTimeString() : new Date().toLocaleTimeString();
            const eventDisplay = formatEventName(e.name);
            const levelColor = getLevelColor(e.level);
            const resultColor = getResultColor(e.result);
            const resultBadge = e.result ? `<span style="background:${resultColor};color:white;padding:1px 5px;border-radius:3px;font-size:0.75em">${e.result}</span>` : '';
            const levelBadge = e.level ? `<span style="background:${levelColor};color:white;padding:1px 5px;border-radius:3px;font-size:0.7em;margin-left:3px">${e.level}</span>` : '';
            const typeBadge = e.event_type ? `<span style="background:#555;color:white;padding:1px 5px;border-radius:3px;font-size:0.7em;margin-left:3px">${e.event_type}</span>` : '';
            return `<div style="padding:6px 8px;margin:3px 0;background:white;border-radius:4px;border-left:3px solid ${levelColor};font-size:0.85em">
                <div style="display:flex;justify-content:space-between;align-items:center">
                    <span style="color:#999;font-size:0.8em">${time}</span>
                    <span>${resultBadge} ${levelBadge} ${typeBadge}</span>
                </div>
                <div><strong>${escapeHtml(eventDisplay)}</strong></div>
                ${e.description ? `<div style="color:#666;font-size:0.85em;margin-top:2px">${escapeHtml(e.description)}</div>` : ''}
            </div>`;
        }).join('');
    } else {
        builtInHtml = '<div style="color:#999;padding:20px;text-align:center">No Subiquity/Curtin events received yet.</div>';
    }
    
    let customHtml = '';
    if (data.updates && data.updates.length > 0) {
        const recentUpdates = data.updates.slice(-MAX_DISPLAY_EVENTS).reverse();
        customHtml = recentUpdates.map(u => {
            const time = u.timestamp ? new Date(u.timestamp).toLocaleTimeString() : new Date().toLocaleTimeString();
            const stageColor = getStageColor(u.stage);
            const icon = getStatusIcon(u.status);
            const progressStr = u.progress !== undefined ? `<span style="color:#666;font-size:0.8em">[${u.progress}%]</span>` : '';
            const stageStr = u.stage ? `<span style="background:${stageColor};color:white;padding:1px 6px;border-radius:3px;font-size:0.7em">${escapeHtml(u.stage)}</span>` : '';
            const statusStr = u.status ? `<span style="color:#555;font-size:0.8em">${escapeHtml(u.status)}</span>` : '';
            return `<div style="padding:8px;margin:4px 0;background:white;border-radius:4px;border-left:3px solid ${stageColor}">
                <div style="display:flex;justify-content:space-between;align-items:center">
                    <span style="color:#999;font-size:0.8em">${time}</span>
                    <span>${stageStr}</span>
                </div>
                <div>${icon} <strong>${escapeHtml(u.message || u.status || 'Status update')}</strong> ${progressStr}</div>
            </div>`;
        }).join('');
    } else {
        customHtml = '<div style="color:#999;padding:20px;text-align:center">No custom progress events received yet.</div>';
    }
    
    const lastBuiltIn = data.builtInEvents && data.builtInEvents.length > 0 
        ? data.builtInEvents[data.builtInEvents.length - 1] 
        : null;
    const lastCustom = data.updates && data.updates.length > 0 
        ? data.updates[data.updates.length - 1] 
        : null;
    const builtInCount = data.builtInEvents ? data.builtInEvents.length : 0;
    const customCount = data.updates ? data.updates.length : 0;
    
    const errorCount = data.builtInEvents ? data.builtInEvents.filter(e => e.level === 'ERROR' || e.result === 'FAILURE').length : 0;
    const warnCount = data.builtInEvents ? data.builtInEvents.filter(e => e.level === 'WARNING' || e.level === 'WARN').length : 0;
    
    let statusPanelHtml = `
        <div style="margin-bottom:12px">
            <div style="font-size:0.9em;color:#666;margin-bottom:4px">Last Built-in Event</div>
            ${lastBuiltIn 
                ? `<div style="font-size:0.85em"><strong>${escapeHtml(formatEventName(lastBuiltIn.name))}</strong><br><span style="color:#999">${escapeHtml(lastBuiltIn.description || 'No description')}</span></div>` 
                : '<div style="color:#999;font-size:0.85em">None yet</div>'}
        </div>
        <div style="margin-bottom:12px">
            <div style="font-size:0.9em;color:#666;margin-bottom:4px">Last Custom Event</div>
            ${lastCustom 
                ? `<div style="font-size:0.85em"><strong>${escapeHtml(lastCustom.message || lastCustom.status || '—')}</strong><br><span style="color:#999">${lastCustom.stage || '—'} · ${lastCustom.progress !== undefined ? lastCustom.progress + '%' : '—'}</span></div>` 
                : '<div style="color:#999;font-size:0.85em">None yet</div>'}
        </div>
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-bottom:12px">
            <div style="background:#f0f0f0;padding:8px;border-radius:6px;text-align:center">
                <div style="font-size:1.4em;font-weight:bold">${builtInCount}</div>
                <div style="font-size:0.75em;color:#666">Subiquity Events</div>
            </div>
            <div style="background:#f0f0f0;padding:8px;border-radius:6px;text-align:center">
                <div style="font-size:1.4em;font-weight:bold">${customCount}</div>
                <div style="font-size:0.75em;color:#666">Progress Events</div>
            </div>
        </div>
        ${errorCount > 0 ? `<div style="background:#f8d7da;padding:8px;border-radius:6px;margin-bottom:8px;font-size:0.85em"><strong>&#10060; ${errorCount} error(s)</strong></div>` : ''}
        ${warnCount > 0 ? `<div style="background:#fff3cd;padding:8px;border-radius:6px;margin-bottom:8px;font-size:0.85em"><strong>&#9888; ${warnCount} warning(s)</strong></div>` : ''}
        <div style="background:#f0f0f0;padding:8px;border-radius:6px;font-size:0.8em;color:#666">
            <div><strong>Config:</strong></div>
            ${data.hostname ? `<div>Hostname: ${escapeHtml(data.hostname)}</div>` : ''}
            ${data.username ? `<div>Username: ${escapeHtml(data.username)}</div>` : ''}
            ${data.wifi_ssid ? `<div>WiFi: ${escapeHtml(data.wifi_ssid)}</div>` : ''}
            ${data.ip ? `<div>IP: ${escapeHtml(data.ip)}</div>` : ''}
            ${!data.hostname && !data.username && !data.wifi_ssid && !data.ip ? '<div>Waiting for config data...</div>' : ''}
        </div>`;
    
    return `<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Mac Pro Installation Monitor</title>
<meta http-equiv="refresh" content="3">
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:linear-gradient(135deg,#667eea,#764ba2);min-height:100vh;padding:15px;color:#333}
.container{max-width:1400px;margin:0 auto;background:white;border-radius:12px;box-shadow:0 20px 60px rgba(0,0,0,0.3);overflow:hidden}
.header{background:linear-gradient(135deg,#667eea,#764ba2);color:white;padding:20px 30px;display:flex;justify-content:space-between;align-items:center}
.header h1{font-size:1.6em;margin:0}
.header .elapsed{font-size:1em;opacity:0.9}
.content{padding:15px 20px}
.progress{height:24px;background:#e9ecef;border-radius:12px;overflow:hidden;margin:10px 0}
.progress-fill{height:100%;background:${color};display:flex;align-items:center;justify-content:center;color:white;font-weight:bold;font-size:0.85em;transition:width 0.3s}
.info-bar{display:flex;gap:15px;align-items:center;margin:8px 0;padding:8px 15px;background:#f8f9fa;border-radius:8px;font-size:0.9em;flex-wrap:wrap}
.info-bar .phase{background:${isPrep ? '#17a2b8' : isInstall ? '#28a745' : '#6c757d'};color:white;padding:4px 12px;border-radius:15px;font-size:0.85em}
.info-bar .status{color:#555}
.three-col{display:grid;grid-template-columns:1fr 1fr 280px;gap:12px;margin:12px 0}
.panel{background:#f8f9fa;border-radius:8px;padding:12px;min-height:300px;display:flex;flex-direction:column}
.panel h3{margin-bottom:8px;color:#333;font-size:0.95em;border-bottom:2px solid #667eea;padding-bottom:5px;display:flex;justify-content:space-between;align-items:center}
.panel h3 .count{font-size:0.75em;background:#667eea;color:white;padding:2px 8px;border-radius:10px}
.events-scroll{flex:1;overflow-y:auto;max-height:420px}
.waiting{text-align:center;padding:60px 20px}
.waiting h2{color:#333;margin:20px 0}
.phase-badge{display:inline-block;padding:8px 16px;background:#2196f3;color:white;border-radius:20px;font-size:0.9em;margin-bottom:15px}
.config-info{background:#f8f9fa;padding:12px;border-radius:8px;margin:12px 0;font-size:0.9em}
.config-info div{margin:4px 0}
.stats{display:flex;gap:20px;margin:10px 0;justify-content:center}
.stat{text-align:center}
.stat-value{font-size:2em;font-weight:bold;color:${color}}
.stat-label{color:#666;font-size:0.85em}
@media(max-width:900px){.three-col{grid-template-columns:1fr}.panel{min-height:200px}}
</style>
</head>
<body>
<div class="container">
<div class="header">
<div>
<h1>Mac Pro Installation Monitor</h1>
<div style="opacity:0.85;font-size:0.85em;margin-top:3px">Ubuntu Server 24.04 — Headless Deploy</div>
</div>
<div class="elapsed">${data.phase !== 'waiting' ? `${mins}m ${secs}s elapsed` : 'Not started'}</div>
</div>
<div class="content">
${data.phase === 'waiting' ? 
'<div class="waiting"><div style="font-size:4em">&#9200;</div><h2>Waiting for Installation to Start</h2><p style="color:#666;margin-top:10px">The Mac Pro hasn\'t started installation yet. Ensure the ISO is booted and autoinstall is running.</p></div>' : 
`${stallWarning}
<div class="stats">
<div class="stat"><div class="stat-value">${pct}%</div><div class="stat-label">${escapeHtml(data.message)}</div></div>
</div>
<div class="progress"><div class="progress-fill" style="width:${pct}%">${pct}%</div></div>
<div class="info-bar">
<span class="phase">${stageLabel}</span>
<span class="status">${escapeHtml(data.status)}</span>
${data.ip ? `<span>IP: ${escapeHtml(data.ip)}</span>` : ''}
<span>Last update: ${data.lastUpdate ? new Date(data.lastUpdate).toLocaleTimeString() : 'n/a'}</span>
</div>
<div class="three-col">
<div class="panel">
<h3>Subiquity/Curtin Events <span class="count">${builtInCount}</span></h3>
<div class="events-scroll">${builtInHtml}</div>
</div>
<div class="panel">
<h3>Custom Progress <span class="count">${customCount}</span></h3>
<div class="events-scroll">${customHtml}</div>
</div>
<div class="panel">
<h3>Status</h3>
${statusPanelHtml}
</div>
</div>`}
</div>
</div>
<script>setTimeout(function(){location.reload()},3000)</script>
</body>
</html>`;
}

// Check if this is a built-in event from subiquity/curtin
function isBuiltInEvent(post) {
    return post.name !== undefined ||
           post.event_type !== undefined ||
           post.origin !== undefined;
}

// Process built-in event from subiquity
function processBuiltInEvent(post) {
    const event = {
        timestamp: post.timestamp || Date.now() / 1000,
        name: post.name || 'unknown',
        description: post.description || '',
        event_type: post.event_type || 'unknown',
        level: post.level || 'INFO',
        result: post.result || null,
        origin: post.origin || 'unknown'
    };
    
    data.builtInEvents.push(event);
    if (data.builtInEvents.length > MAX_BUILT_IN_EVENTS) {
        data.builtInEvents = data.builtInEvents.slice(-MAX_BUILT_IN_EVENTS);
    }
    
    const eventName = String(post.name || '');
    if (eventName.includes('subiquity')) {
        if (data.phase === 'waiting') {
            data.phase = 'install';
            if (!data.startTime) {
                data.startTime = new Date().toISOString();
            }
        }
    }
    
    const levelTag = event.level || 'INFO';
    const resultTag = event.result ? ` [${event.result}]` : '';
    const typeTag = event.event_type ? ` <${event.event_type}>` : '';
    console.log(`[${new Date().toLocaleTimeString()}] [BUILTIN] [${levelTag}]${typeTag}${resultTag} ${event.name}: ${event.description}`);
    
    data.lastUpdate = new Date().toISOString();
    save();
}

function processCustomEvent(post) {
    if (typeof post.progress === 'number') {
        data.progress = sanitizeProgress(post.progress);
    }
    if (post.stage !== undefined) {
        data.stage = sanitizeString(String(post.stage), 50);
    }
    if (typeof post.status === 'string') {
        data.status = sanitizeString(post.status, 100);
    }
    if (typeof post.message === 'string') {
        data.message = sanitizeString(post.message, 500);
    }
    
    const stageStr = String(post.stage);
    if (stageStr === 'init' || stageStr.startsWith('prep') || stageStr === 'early-init') {
        data.phase = 'prep';
        if (!data.prepStartTime) {
            data.prepStartTime = new Date().toISOString();
            console.log('\n[PREP] Preparation phase started!');
        }
        data.startTime = new Date(data.prepStartTime);
    } else if (/^[0-9]+$/.test(stageStr) || stageStr === '1' || stageStr === '2' || stageStr === 'late' || stageStr === 'early' || stageStr.startsWith('late-')) {
        if (data.phase !== 'install' && data.progress > 0) {
            console.log('\n[INSTALL] Installation phase started!');
        }
        data.phase = 'install';
        if (!data.startTime || data.phase === 'waiting') {
            data.startTime = new Date().toISOString();
        }
    } else if (stageStr === 'complete' || stageStr === 'done') {
        data.phase = 'install';
        data.progress = Math.max(data.progress, 100);
    }
    
    if (!data.startTime && data.progress > 0) {
        data.startTime = new Date().toISOString();
    }
    data.lastUpdate = new Date().toISOString();
    
    if (post.hostname) data.hostname = sanitizeString(String(post.hostname), 100);
    if (post.username) data.username = sanitizeString(String(post.username), 100);
    if (post.wifi_ssid) data.wifi_ssid = sanitizeString(String(post.wifi_ssid), 100);
    if (post.ip) data.ip = sanitizeString(String(post.ip), 50);
    
    data.updates.push({ timestamp: new Date().toISOString(), ...post });
    if (data.updates.length > MAX_UPDATES) {
        data.updates = data.updates.slice(-MAX_UPDATES);
    }
    
    if (data.progress >= 100) {
        console.log('\n[COMPLETE] Installation complete!');
        if (data.ip) console.log('   IP: ' + data.ip);
    }
    
    save();
    
    const phaseLabel = data.phase === 'prep' ? 'PREP' : data.phase === 'install' ? 'INST' : 'WAIT';
    console.log(`[${new Date().toLocaleTimeString()}] [CUSTOM] [${phaseLabel}] ${post.stage || '?'} | ${post.status || '?'} | ${post.progress !== undefined ? post.progress + '%' : '?'} | ${post.message || '?'}`);
}

function sanitizeString(val, maxLen) {
    if (typeof val !== 'string') return '';
    return val.slice(0, maxLen);
}

function sanitizeProgress(val) {
    if (typeof val !== 'number') return 0;
    return Math.max(PROGRESS_MIN, Math.min(PROGRESS_MAX, Math.floor(val)));
}

const server = http.createServer((req, res) => {
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
    
    if (req.method === 'OPTIONS') {
        res.writeHead(200);
        res.end();
        return;
    }
    
    if (req.method === 'POST' && req.url === '/webhook') {
        const clientIP = req.socket.remoteAddress || 'unknown';
        const now = Date.now();
        const clientHits = rateLimitMap.get(clientIP) || { count: 0, windowStart: now };
        if (now - clientHits.windowStart > RATE_LIMIT_WINDOW_MS) {
            clientHits.count = 0;
            clientHits.windowStart = now;
        }
        clientHits.count++;
        rateLimitMap.set(clientIP, clientHits);
        if (clientHits.count > RATE_LIMIT_MAX_REQUESTS) {
            res.writeHead(429, {'Content-Type': 'application/json'});
            res.end(JSON.stringify({error: 'Rate limit exceeded'}));
            return;
        }
        let body = '';
        let tooLarge = false;
        req.on('data', chunk => {
            if (body.length + chunk.length > MAX_BODY_SIZE) {
                tooLarge = true;
                return;
            }
            body += chunk;
        });
        req.on('error', (e) => {
            console.error('Request error:', e.message);
            res.writeHead(400, {'Content-Type': 'application/json'});
            res.end(JSON.stringify({error: 'Bad request'}));
        });
        req.on('end', () => {
            if (tooLarge) {
                res.writeHead(413, {'Content-Type': 'application/json'});
                res.end(JSON.stringify({error: 'Payload too large'}));
                return;
            }
            try {
                const post = JSON.parse(body);
                
                if (isBuiltInEvent(post)) {
                    processBuiltInEvent(post);
                    res.writeHead(200, {'Content-Type': 'application/json'});
                    res.end(JSON.stringify({status: 'ok', type: 'builtin'}));
                } else {
                    processCustomEvent(post);
                    res.writeHead(200, {'Content-Type': 'application/json'});
                    res.end(JSON.stringify({status: 'ok', progress: data.progress}));
                }
            } catch (e) {
                res.writeHead(400);
                res.end(JSON.stringify({error: 'Invalid JSON'}));
            }
        });
        return;
    }
    
    if (req.method === 'GET' && req.url === '/api/progress') {
        res.writeHead(200, {'Content-Type': 'application/json'});
        res.end(JSON.stringify(data, null, 2));
        return;
    }
    
    if (req.method === 'GET' && req.url === '/') {
        res.writeHead(200, {'Content-Type': 'text/html; charset=utf-8'});
        res.end(html());
        return;
    }
    
    res.writeHead(404);
    res.end('Not Found');
});

load();

setInterval(() => {
    checkStalled();
    const now = Date.now();
    for (const [ip, entry] of rateLimitMap) {
        if (now - entry.windowStart > 60000) rateLimitMap.delete(ip);
    }
}, 60000);

server.listen(PORT, HOST, () => {
    const ips = getIPs();
    console.log('\n+============================================+');
    console.log('|  Mac Pro Installation Monitor               |');
    console.log('+============================================+\n');
    console.log('Server running!\n');
    console.log('Dashboard:\n');
    console.log('   http://localhost:' + PORT);
    ips.forEach(ip => console.log('   http://' + ip + ':' + PORT));
    console.log('\nWebhook URL (copy this for autoinstall.yaml):\n');
    ips.forEach(ip => console.log('   http://' + ip + ':' + PORT + '/webhook'));
    console.log('\nFeatures:');
    console.log('   - Receives ALL Subiquity/Curtin events (DEBUG level)');
    console.log('   - Receives custom progress from early/late commands');
    console.log('   - 3-pane view: Subiquity | Custom Progress | Status');
    console.log('   - Monitors PREP and INSTALL phases');
    console.log('   - Console logs all events for debugging');
    console.log('');
});