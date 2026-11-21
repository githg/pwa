// Auto-generated from instant_capture_pwa.html — shared by Counter & Admin PWAs
const GAS_URL = "https://script.google.com/macros/s/AKfycbxu_xJtq3VWTCtwu9erZONgU4evkPLpSYWnmMgo-1mHA_Bl63gvZYKvAwiNTJjEIlXufA/exec";

function escapeHtml(str) {
    return String(str == null ? '' : str)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}

function formatEntryRef(entry, serialNum) {
    if (!entry) return '';
    const cid = entry.counterId != null ? String(entry.counterId) : '0';
    let modes = '';
    if (Number(entry.cash || 0) > 0) modes += 'Cs';
    if (Number(entry.qr || 0) > 0) modes += 'Qr';
    if (Number(entry.online || 0) > 0) modes += 'On';
    if (Number(entry.pos || 0) > 0) modes += 'Ps';
    if (Number(entry.ips || 0) > 0) modes += 'Ip';
    if (Number(entry.esewa || 0) > 0) modes += 'Es';
    if (Number(entry.cheque || 0) > 0) modes += 'Ch';
    if (Number(entry.credit || 0) > 0) modes += 'Cr';
    if (!modes) modes = entry.isVoid ? 'Vd' : 'Pd';
    const dStr = String(entry.date || getLocalTodayStr());
    const parts = dStr.split('-');
    const mmdd = parts.length === 3 ? (parts[1] + parts[2]) : dStr.replace(/\D/g, '').slice(-4);
    const sn = serialNum || 1;
    return `${cid}-${modes}-${mmdd}-${sn}`;
}

function formatCanonicalTimestamp(d = new Date()) {
    const hh = String(d.getHours()).padStart(2, '0');
    const min = String(d.getMinutes()).padStart(2, '0');
    const dd = String(d.getDate()).padStart(2, '0');
    const mm = String(d.getMonth() + 1).padStart(2, '0');
    const yy = String(d.getFullYear()).slice(-2);
    return `${hh}:${min} ${dd}/${mm}/${yy}`;
}

function getEntrySortKey(entry) {
    if (!entry) return 0;
    let dateStr = String(entry.date || '');
    const ts = String(entry.timestamp || '').trim();
    if (!dateStr && ts) {
        const mDate = ts.match(/(\d{1,2})\/(\d{1,2})\/(\d{2,4})/);
        if (mDate) {
            const dd = mDate[1].padStart(2, '0');
            const mm = mDate[2].padStart(2, '0');
            const yy = mDate[3].length === 2 ? ('20' + mDate[3]) : mDate[3];
            dateStr = `${yy}-${mm}-${dd}`;
        }
    }
    const dp = dateStr.split('-');
    if (dp.length === 3) {
        const y = parseInt(dp[0], 10), m = parseInt(dp[1], 10), d = parseInt(dp[2], 10);
        let hh = 0, min = 0;
        const mTime = ts.match(/^(\d{1,2}):(\d{2})(?:\s*(AM|PM))?/i);
        if (mTime) {
            hh = parseInt(mTime[1], 10) || 0;
            min = parseInt(mTime[2], 10) || 0;
            if (mTime[3]) {
                const ap = mTime[3].toUpperCase();
                if (ap === 'PM' && hh < 12) hh += 12;
                if (ap === 'AM' && hh === 12) hh = 0;
            }
        }
        if (!isNaN(y) && !isNaN(m) && !isNaN(d)) {
            const baseMs = Date.UTC(y, m - 1, d, hh, min, 0, 0);
            const idNum = Number(entry.id);
            const subMin = (!isNaN(idNum) && idNum > 0) ? (idNum % 60000) : 0;
            return baseMs + subMin;
        }
    }
    const fallback = Number(entry.id);
    return isNaN(fallback) ? 0 : fallback;
}

function compareEntriesChrono(a, b) {
    const diff = getEntrySortKey(a) - getEntrySortKey(b);
    if (diff !== 0) return diff;
    return String(a && a.id || '').localeCompare(String(b && b.id || ''));
}

function formatDisplay(seq) {
    return seq.replace(/\*/g, ' × ').replace(/\//g, ' ÷ ').replace(/\+/g, ' + ').replace(/-/g, ' - ');
}

function safeEval(str) {
    if (/^[0-9+\-*/.]*$/.test(str)) {
        try {
            let result = new Function(`return (${str})`)();
            if (typeof result === 'number' && !isNaN(result)) {
                if (result % 1 !== 0) {
                    return parseFloat(result.toFixed(8));
                }
                return result;
            }
        } catch (e) {
            return "Error";
        }
    }
    return "Error";
}

