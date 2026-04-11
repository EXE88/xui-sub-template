let DEMO_DATA = (typeof window !== 'undefined' && window.DEMO_DATA) ? window.DEMO_DATA : {
    subId: 'ez7zcdex151qfsyw',
    status: 'active',
    downloaded: 2634022912,
    uploaded: 897581056,
    totalUsed: 3531603968,
    totalQuota: 10737418240,
    remained: 7205814272,
    lastOnline: new Date(Date.now() - 2 * 60 * 60 * 1000).toISOString(),
    expiry: '2026-04-30T23:59:59Z',
    usageChart: generateUsageChartData(),
    config: 'vless://example-uuid@server.domain.com:443?encryption=none&security=tls&type=ws&host=server.domain.com&path=%2Fws#MyConfig'
};

function generateUsageChartData() {
    const data = [];
    const now = new Date();
    const hoursBack = 24;

    for (let i = hoursBack; i >= 0; i--) {
        const time = new Date(now.getTime() - i * 60 * 60 * 1000);
        const hour = time.getHours();
        let baseUsage;

        if (hour >= 9 && hour <= 23) {
            baseUsage = 50 + Math.random() * 150;
        } else if (hour >= 0 && hour <= 5) {
            baseUsage = 5 + Math.random() * 20;
        } else {
            baseUsage = 20 + Math.random() * 50;
        }

        data.push({
            time: time.toISOString().slice(0, 16),
            used: Math.round(baseUsage * 1024 * 1024)
        });
    }
    console.log(data);
    return data;
}
