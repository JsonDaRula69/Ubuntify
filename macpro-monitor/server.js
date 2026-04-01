const http = require('http');
const fs = require('fs');
const os = require('os');

const PORT = 8080;
const HOST = '0.0.0.0';
const MAX_BODY_SIZE = 64 * 1024;

// Constants
const MAX_UPDATES = 100;
const MAX_DISPLAY_UPDATES = 15;
const PROGRESS_MIN = 0;
const PROGRESS_MAX = 100;
const STALL_WARNING_MS = 5 * 60 * 1000;
const STALL_ERROR_MS = 15 * 60 * 1000;

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

// Generate HTML
function html() {
    const pct = data.progress;
    const color = pct < 50 ? '#ffc107' : pct < 90 ? '#17a2b8' : '#28a745';
    
    const isPrep = data.phase === 'prep';
    const isInstall = data.phase === 'install';
    
    // Use appropriate start time for elapsed calculation
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
        stallWarning = '<div style="background:#dc3545;color:white;padding:20px;border-radius:8px;margin:20px 0"><strong>⚠ STALLED INSTALLATION</strong><br>No update for ' + stallTime + ' minutes. Check Mac Pro status.</div>';
    } else if (data.lastUpdate && data.phase !== 'waiting') {
        const elapsed2 = Date.now() - new Date(data.lastUpdate).getTime();
        if (elapsed2 >= STALL_WARNING_MS && elapsed2 < STALL_ERROR_MS) {
            const warnMins = Math.floor(elapsed2 / 60000);
            stallWarning = '<div style="background:#ffc107;color:black;padding:15px;border-radius:8px;margin:20px 0"><strong>⚠ Warning:</strong> ' + warnMins + ' minutes since last update</div>';
        }
    }
    
    let stageHtml = '';
    if (isPrep) {
        // Match script stages: copying(5), copied(10), iso_verified(20), partitions(30), files_copied(40), 
        // initrd(45), drivers(50), config(60), boot_config(70), boot_ready(80), ready(90), complete(100)
        stageHtml = `
        <div class="stages">
        <div class="stage ${pct >= 10 ? 'complete' : pct >= 5 ? 'active' : ''}">✓ Copying Drivers</div>
        <div class="stage ${pct >= 20 ? 'complete' : pct >= 10 ? 'active' : ''}">✓ ISO Verified</div>
        <div class="stage ${pct >= 30 ? 'complete' : pct >= 20 ? 'active' : ''}">✓ Partitions Mounted</div>
        <div class="stage ${pct >= 45 ? 'complete' : pct >= 40 ? 'active' : ''}">✓ Files Copied</div>
        <div class="stage ${pct >= 50 ? 'complete' : pct >= 45 ? 'active' : ''}">✓ Initrd Replaced</div>
        <div class="stage ${pct >= 60 ? 'complete' : pct >= 50 ? 'active' : ''}">✓ Drivers Embedded</div>
        <div class="stage ${pct >= 70 ? 'complete' : pct >= 60 ? 'active' : ''}">✓ Config Created</div>
        <div class="stage ${pct >= 80 ? 'complete' : pct >= 70 ? 'active' : ''}">✓ Boot Config</div>
        <div class="stage ${pct >= 90 ? 'complete' : pct >= 80 ? 'active' : ''}">✓ Ready for Reboot</div>
        <div class="stage ${pct >= 100 ? 'complete' : pct >= 90 ? 'active' : ''}">✓ Complete</div>
        </div>`;
    } else if (isInstall) {
        stageHtml = `
        <div class="stages">
        <div class="stage ${pct >= 5 ? 'complete' : pct > 0 ? 'active' : ''}">✓ Installation Started</div>
        <div class="stage ${pct >= 10 ? 'complete' : pct >= 5 ? 'active' : ''}">✓ Drivers Installing</div>
        <div class="stage ${pct >= 30 ? 'complete' : pct >= 10 ? 'active' : ''}">✓ Partitioning</div>
        <div class="stage ${pct >= 50 ? 'complete' : pct >= 30 ? 'active' : ''}">✓ WiFi Config</div>
        <div class="stage ${pct >= 70 ? 'complete' : pct >= 50 ? 'active' : ''}">✓ SSH Setup</div>
        <div class="stage ${pct >= 90 ? 'complete' : pct >= 70 ? 'active' : ''}">✓ Final Config</div>
        <div class="stage ${pct >= 100 ? 'complete' : pct >= 90 ? 'active' : ''}">✓ Complete</div>
        </div>`;
    }
    
    return `<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Mac Pro Installation Monitor</title>
<meta http-equiv="refresh" content="5">
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:linear-gradient(135deg,#667eea,#764ba2);min-height:100vh;padding:20px;color:#333}
.container{max-width:900px;margin:0 auto;background:white;border-radius:12px;box-shadow:0 20px 60px rgba(0,0,0,0.3);overflow:hidden}
.header{background:linear-gradient(135deg,#667eea,#764ba2);color:white;padding:40px 30px;text-align:center}
.header h1{font-size:2.5em;margin-bottom:10px}
.content{padding:30px}
.progress{height:40px;background:#e9ecef;border-radius:20px;overflow:hidden;margin:20px 0}
.progress-fill{height:100%;background:${color};width:${pct}%;display:flex;align-items:center;justify-content:center;color:white;font-weight:bold;font-size:1.1em}
.status{padding:20px;background:#f8f9fa;border-radius:8px;margin:20px 0;border-left:4px solid ${color}}
.info{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:15px;margin:20px 0}
.info div{background:#f8f9fa;padding:15px;border-radius:8px;text-align:center}
.info .label{color:#666;font-size:0.9em;margin-bottom:5px}
.info .value{font-size:1.5em;font-weight:bold}
.stages{margin:30px 0}
.stage{padding:15px;margin:10px 0;background:#f8f9fa;border-radius:8px;border-left:4px solid #dee2e6}
.stage.active{background:#e3f2fd;border-color:#2196f3}
.stage.complete{background:#e8f5e9;border-color:#4caf50}
.timeline{max-height:300px;overflow-y:auto;background:#f8f9fa;border-radius:8px;padding:15px;margin-top:20px}
.update{padding:10px;border-left:3px solid #2196f3;margin:10px 0;background:white;border-radius:4px}
.update .time{color:#999;font-size:0.85em;margin-bottom:5px}
.waiting{text-align:center;padding:60px 20px}
.waiting h2{color:#333;margin:20px 0}
.phase-badge{display:inline-block;padding:8px 16px;background:#2196f3;color:white;border-radius:20px;font-size:0.9em;margin-bottom:15px}
.config-info{background:#f8f9fa;padding:15px;border-radius:8px;margin:15px 0;font-size:0.9em}
.config-info div{margin:5px 0}
</style>
</head>
<body>
<div class="container">
<div class="header">
<h1>Mac Pro Installation Monitor</h1>
<div style="opacity:0.9">Ubuntu Server Installation Progress</div>
</div>
<div class="content">
${data.phase === 'waiting' ? 
'<div class="waiting"><div style="font-size:4em">[WAITING]</div><h2>Waiting for Installation to Start</h2><p>The Mac Pro hasn\'t started installation yet.</p><p>Run the preparation script on the Mac Pro to begin.</p></div>' : 
((data.phase === 'prep' ? '<div class="phase-badge">PREP Phase</div>' : '<div class="phase-badge">INSTALL Phase</div>') +
(data.hostname || data.username || data.wifi_ssid ? 
'<div class="config-info">' +
(data.hostname ? '<div><strong>Hostname:</strong> ' + escapeHtml(data.hostname) + '</div>' : '') +
(data.username ? '<div><strong>Username:</strong> ' + escapeHtml(data.username) + '</div>' : '') +
(data.wifi_ssid ? '<div><strong>WiFi:</strong> ' + escapeHtml(data.wifi_ssid) + '</div>' : '') +
'</div>' : ''))}
<div style="text-align:center;margin-bottom:20px">
<div style="font-size:3em;font-weight:bold;color:${color}">${pct}%</div>
<div style="color:#666;margin-top:5px">${escapeHtml(data.message)}</div>
</div>
${stallWarning}
<div class="progress"><div class="progress-fill">${pct}%</div></div>
<div class="info">
<div><div class="label">Phase</div><div class="value" style="font-size:1em">${stageLabel}</div></div>
<div><div class="label">Stage</div><div class="value">${currentStage}/${totalStages}</div></div>
<div><div class="label">Time</div><div class="value">${mins}m ${secs}s</div></div>
<div><div class="label">Status</div><div class="value" style="font-size:1em">${data.status.toUpperCase()}</div></div>
${data.ip ? `<div><div class="label">IP</div><div class="value" style="font-size:1em">${data.ip}</div></div>` : ''}
</div>
${stageHtml}
${data.updates.length > 0 ? '<div class="timeline"><h3>Updates</h3>' + data.updates.slice(-MAX_DISPLAY_UPDATES).reverse().map(u => '<div class="update"><div class="time">' + new Date(u.timestamp).toLocaleTimeString() + '</div><div>' + escapeHtml(u.message || '') + '</div></div>').join('') + '</div></div></div></div>' : ''}
<script>setTimeout(()=>location.reload(),5000)</script>
</body>
</html>`;
}

// Request handler
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
                
                // Input validation
                if (typeof post.progress === 'number') {
                    data.progress = Math.max(PROGRESS_MIN, Math.min(PROGRESS_MAX, Math.floor(post.progress)));
                }
                if (post.stage !== undefined) {
                    data.stage = post.stage;
                }
                if (typeof post.status === 'string' && post.status.length < 100) {
                    data.status = post.status;
                }
                if (typeof post.message === 'string' && post.message.length < 500) {
                    data.message = post.message;
                }
                
                // Detect phase based on stage
                const stageStr = String(post.stage);
                if (stageStr === 'init' || stageStr.startsWith('prep')) {
                    data.phase = 'prep';
                    if (!data.prepStartTime) {
                        data.prepStartTime = new Date().toISOString();
                        console.log('\n[PREP] Preparation phase started!');
                    }
                    data.startTime = new Date(data.prepStartTime);
                } else if (/^[0-9]+$/.test(stageStr) || stageStr === '1' || stageStr === '2') {
                    if (data.phase !== 'install' && data.progress > 0) {
                        console.log('\n[INSTALL] Installation phase started!');
                    }
                    data.phase = 'install';
                    if (!data.startTime || data.phase === 'waiting') {
                        data.startTime = new Date().toISOString();
                    }
                }
                
                if (!data.startTime && data.progress > 0) {
                    data.startTime = new Date().toISOString();
                }
                data.lastUpdate = new Date().toISOString();
                
                // Store config info (escaped for display)
                if (post.hostname) data.hostname = String(post.hostname).slice(0, 100);
                if (post.username) data.username = String(post.username).slice(0, 100);
                if (post.wifi_ssid) data.wifi_ssid = String(post.wifi_ssid).slice(0, 100);
                if (post.ip) data.ip = String(post.ip).slice(0, 50);
                
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
                console.log(`[${new Date().toLocaleTimeString()}] [${phaseLabel}] ${data.message} (${data.progress}%)`);
                res.writeHead(200, {'Content-Type': 'application/json'});
                res.end(JSON.stringify({status: 'ok', progress: data.progress}));
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
}, 60000);

server.listen(PORT, HOST, () => {
    const ips = getIPs();
    console.log('\n╔════════════════════════════════════════╗');
    console.log('║   Mac Pro Installation Monitor          ║');
    console.log('╚════════════════════════════════════════╝\n');
    console.log('✓ Server running!\n');
    console.log('📊 Dashboard:\n');
    console.log('   http://localhost:' + PORT);
    ips.forEach(ip => console.log('   http://' + ip + ':' + PORT));
    console.log('\n🔗 Webhook URL (copy this):\n');
    ips.forEach(ip => console.log('   http://' + ip + ':' + PORT + '/webhook'));
    console.log('\n📝 Features:');
    console.log('   - Monitors PREP phase (driver copy, ISO extraction)');
    console.log('   - Monitors INSTALL phase (Ubuntu autoinstall)');
    console.log('   - Shows hostname, username, WiFi config');
    console.log('   - Displays installation IP when available');
    console.log('\n');
});
