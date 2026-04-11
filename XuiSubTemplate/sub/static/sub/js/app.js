let chart = null;
let currentView = 'hourly';
let refreshTimer = null;
let isConfigVisible = false;

// DOM Elements
const elements = {
    themeToggle: document.getElementById('theme-toggle'),
    refreshBtn: document.getElementById('refresh-btn'),
    statusBadge: document.getElementById('status-badge'),
    subId: document.getElementById('sub-id'),
    downloaded: document.getElementById('downloaded'),
    uploaded: document.getElementById('uploaded'),
    lastOnline: document.getElementById('last-online'),
    expiry: document.getElementById('expiry'),
    expiryDays: document.getElementById('expiry-days'),
    quotaPercent: document.getElementById('quota-percent'),
    progressFill: document.getElementById('progress-fill'),
    quotaDownloaded: document.getElementById('quota-downloaded'),
    quotaUploaded: document.getElementById('quota-uploaded'),
    quotaRemaining: document.getElementById('quota-remaining'),
    quotaTotal: document.getElementById('quota-total'),
    usageChart: document.getElementById('usageChart'),
    chartBtns: document.querySelectorAll('.chart-btn'),
    configText: document.getElementById('config-text'),
    toggleConfig: document.getElementById('toggle-config'),
    copyConfig: document.getElementById('copy-config'),
    toast: document.getElementById('toast'),
    lastUpdated: document.getElementById('last-updated')
};

// Utility Functions
const utils = {
    formatBytes(bytes, decimals = 2) {
        if (bytes === 0) return '0 B';
        const k = 1024;
        const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
        const i = Math.floor(Math.log(bytes) / Math.log(k));
        return parseFloat((bytes / Math.pow(k, i)).toFixed(decimals)) + ' ' + sizes[i];
    },

    formatDate(dateString) {
        const date = new Date(dateString);
        return date.toLocaleDateString('en-US', {
            month: 'short',
            day: 'numeric',
            year: 'numeric'
        });
    },

    formatTime(dateString) {
        const date = new Date(dateString);
        return date.toLocaleTimeString('en-US', {
            hour: '2-digit',
            minute: '2-digit'
        });
    },

    getRelativeTime(dateString) {
        const date = new Date(dateString);
        const now = new Date();
        const diffMs = now - date;
        const diffMins = Math.floor(diffMs / 60000);
        const diffHours = Math.floor(diffMs / 3600000);
        const diffDays = Math.floor(diffMs / 86400000);

        if (diffMins < 1) return 'just now';
        if (diffMins < 60) return `${diffMins} min${diffMins > 1 ? 's' : ''} ago`;
        if (diffHours < 24) return `${diffHours} hour${diffHours > 1 ? 's' : ''} ago`;
        return `${diffDays} day${diffDays > 1 ? 's' : ''} ago`;
    },

    getDaysRemaining(dateString) {
        const expiry = new Date(dateString);
        const now = new Date();
        const diffDays = Math.ceil((expiry - now) / 86400000);
        if (diffDays < 0) return 'Expired';
        if (diffDays === 0) return 'Expires today';
        if (diffDays === 1) return '1 day remaining';
        return `${diffDays} days remaining`;
    }
};

// Theme Management
function initTheme() {
    const savedTheme = localStorage.getItem('theme');
    const prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;

    if (savedTheme === 'light' || (!savedTheme && !prefersDark)) {
        document.body.classList.remove('dark');
    } else {
        document.body.classList.add('dark');
    }
}

function toggleTheme() {
    document.body.classList.toggle('dark');
    const isDark = document.body.classList.contains('dark');
    localStorage.setItem('theme', isDark ? 'dark' : 'light');

    // Update chart colors
    if (chart) {
        updateChartColors();
    }
}

// Chart Functions
function getChartColors() {
    const isDark = document.body.classList.contains('dark');
    return {
        primary: isDark ? '#818cf8' : '#6366f1',
        gradientStart: isDark ? 'rgba(129, 140, 248, 0.4)' : 'rgba(99, 102, 241, 0.4)',
        gradientEnd: isDark ? 'rgba(129, 140, 248, 0.0)' : 'rgba(99, 102, 241, 0.0)',
        grid: isDark ? 'rgba(255, 255, 255, 0.06)' : 'rgba(0, 0, 0, 0.06)',
        text: isDark ? '#94a3b8' : '#64748b'
    };
}

function createChart(data) {
    const ctx = elements.usageChart.getContext('2d');
    const colors = getChartColors();

    // Create gradient
    const gradient = ctx.createLinearGradient(0, 0, 0, 300);
    gradient.addColorStop(0, colors.gradientStart);
    gradient.addColorStop(1, colors.gradientEnd);

    const chartData = prepareChartData(data, currentView);

    if (chart) {
        chart.destroy();
    }

    chart = new Chart(ctx, {
        type: 'line',
        data: {
            labels: chartData.labels,
            datasets: [{
                label: 'Data Usage',
                data: chartData.values,
                fill: true,
                backgroundColor: gradient,
                borderColor: colors.primary,
                borderWidth: 2.5,
                tension: 0.4,
                pointRadius: 0,
                pointHoverRadius: 6,
                pointHoverBackgroundColor: colors.primary,
                pointHoverBorderColor: '#fff',
                pointHoverBorderWidth: 2
            }]
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            interaction: {
                mode: 'index',
                intersect: false
            },
            plugins: {
                legend: {
                    display: false
                },
                tooltip: {
                    backgroundColor: document.body.classList.contains('dark') ? '#1e1e2a' : '#fff',
                    titleColor: document.body.classList.contains('dark') ? '#f1f5f9' : '#0f172a',
                    bodyColor: document.body.classList.contains('dark') ? '#94a3b8' : '#64748b',
                    borderColor: document.body.classList.contains('dark') ? '#2a2a3a' : '#e2e8f0',
                    borderWidth: 1,
                    padding: 12,
                    cornerRadius: 8,
                    displayColors: false,
                    callbacks: {
                        title: function(items) {
                            return items[0].label;
                        },
                        label: function(context) {
                            return 'Usage: ' + utils.formatBytes(context.raw);
                        }
                    }
                }
            },
            scales: {
                x: {
                    grid: {
                        display: false
                    },
                    ticks: {
                        color: colors.text,
                        font: {
                            size: 11
                        },
                        maxRotation: 0,
                        maxTicksLimit: 8
                    },
                    border: {
                        display: false
                    }
                },
                y: {
                    grid: {
                        color: colors.grid,
                        drawBorder: false
                    },
                    ticks: {
                        color: colors.text,
                        font: {
                            size: 11
                        },
                        callback: function(value) {
                            return utils.formatBytes(value, 0);
                        },
                        maxTicksLimit: 5
                    },
                    border: {
                        display: false
                    },
                    beginAtZero: true
                }
            }
        }
    });
}

function prepareChartData(usageChart, view) {
    if (view === 'daily') {
        // Aggregate by day
        const dailyData = {};
        usageChart.forEach(item => {
            const date = item.time.split('T')[0];
            if (!dailyData[date]) {
                dailyData[date] = 0;
            }
            dailyData[date] += item.used;
        });

        const labels = Object.keys(dailyData).map(date => {
            const d = new Date(date);
            return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
        });
        const values = Object.values(dailyData);

        return { labels, values };
    } else {
        // Hourly view
        const labels = usageChart.map(item => {
            const date = new Date(item.time);
            return date.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' });
        });
        const values = usageChart.map(item => item.used);

        return { labels, values };
    }
}

function updateChartColors() {
    const colors = getChartColors();
    const ctx = elements.usageChart.getContext('2d');
    const gradient = ctx.createLinearGradient(0, 0, 0, 300);
    gradient.addColorStop(0, colors.gradientStart);
    gradient.addColorStop(1, colors.gradientEnd);

    chart.data.datasets[0].backgroundColor = gradient;
    chart.data.datasets[0].borderColor = colors.primary;
    chart.options.scales.x.ticks.color = colors.text;
    chart.options.scales.y.ticks.color = colors.text;
    chart.options.scales.y.grid.color = colors.grid;
    chart.options.plugins.tooltip.backgroundColor = document.body.classList.contains('dark') ? '#1e1e2a' : '#fff';
    chart.options.plugins.tooltip.titleColor = document.body.classList.contains('dark') ? '#f1f5f9' : '#0f172a';
    chart.options.plugins.tooltip.bodyColor = document.body.classList.contains('dark') ? '#94a3b8' : '#64748b';
    chart.options.plugins.tooltip.borderColor = document.body.classList.contains('dark') ? '#2a2a3a' : '#e2e8f0';

    chart.update();
}

// UI Update Functions
function updateStatus(status) {
    const badge = elements.statusBadge;
    badge.className = 'status-badge';

    const statusText = badge.querySelector('.status-text');

    switch (status.toLowerCase()) {
        case 'active':
            badge.classList.add('status-active');
            statusText.textContent = 'Active';
            break;
        case 'deactive':
            badge.classList.add('status-deactive');
            statusText.textContent = 'Deactive';
            break;
        case 'expired':
            badge.classList.add('status-expired');
            statusText.textContent = 'Expired';
            break;
        default:
            badge.classList.add('status-active');
            statusText.textContent = status;
    }
}

function updateDashboard(data) {
    // Subscription ID
    elements.subId.textContent = data.subId;

    // Status
    updateStatus(data.status);

    // Stats
    elements.downloaded.textContent = utils.formatBytes(data.downloaded);
    elements.uploaded.textContent = utils.formatBytes(data.uploaded);
    elements.lastOnline.textContent = utils.getRelativeTime(data.lastOnline);
    elements.expiry.textContent = utils.formatDate(data.expiry);
    elements.expiryDays.textContent = utils.getDaysRemaining(data.expiry);

    // Quota
    const usedPercent = ((data.totalUsed / data.totalQuota) * 100).toFixed(1);
    elements.quotaPercent.textContent = usedPercent + '%';
    elements.progressFill.style.width = usedPercent + '%';
    elements.quotaDownloaded.textContent = utils.formatBytes(data.downloaded);
    elements.quotaUploaded.textContent = utils.formatBytes(data.uploaded);
    elements.quotaRemaining.textContent = utils.formatBytes(data.remained);
    elements.quotaTotal.textContent = utils.formatBytes(data.totalQuota);

    // Config
    elements.configText.textContent = data.config;

    // Chart
    createChart(data.usageChart);

    // Last updated
    elements.lastUpdated.textContent = 'Last updated: ' + new Date().toLocaleTimeString();
}

// Config Functions
function toggleConfigVisibility() {
    isConfigVisible = !isConfigVisible;
    const toggleBtn = elements.toggleConfig;
    const configText = elements.configText;
    const placeholder = document.querySelector('.config-placeholder');

    if (isConfigVisible) {
        configText.classList.remove('hidden');
        placeholder.style.display = 'none';
        toggleBtn.classList.add('showing');
        toggleBtn.querySelector('.toggle-text').textContent = 'Hide';
    } else {
        configText.classList.add('hidden');
        placeholder.style.display = 'block';
        toggleBtn.classList.remove('showing');
        toggleBtn.querySelector('.toggle-text').textContent = 'Show';
    }
}

async function copyConfig() {
    const config = elements.configText.textContent;

    try {
        await navigator.clipboard.writeText(config);
        showToast('Copied to clipboard!');
    } catch (err) {
        // Fallback for older browsers
        const textarea = document.createElement('textarea');
        textarea.value = config;
        textarea.style.position = 'fixed';
        textarea.style.opacity = '0';
        document.body.appendChild(textarea);
        textarea.select();
        document.execCommand('copy');
        document.body.removeChild(textarea);
        showToast('Copied to clipboard!');
    }
}

function showToast(message) {
    const toast = elements.toast;
    toast.querySelector('.toast-message').textContent = message;
    toast.classList.add('show');

    setTimeout(() => {
        toast.classList.remove('show');
    }, 3000);
}

// Data fetching removed: this file is intended for server-rendered templates.
// Provide `window.DEMO_DATA` from your Django view (JSON-serialized) to populate the UI.
// We will render once from `DEMO_DATA` on init.

// Chart View Toggle
function setChartView(view) {
    currentView = view;

    // Update buttons
    elements.chartBtns.forEach(btn => {
        btn.classList.toggle('active', btn.dataset.view === view);
    });

    // Recreate chart with new view
    createChart(DEMO_DATA.usageChart);
}

// Event Listeners
function initEventListeners() {
    // Theme toggle
    elements.themeToggle.addEventListener('click', toggleTheme);

    // Refresh button — re-render from current DEMO_DATA (no network call)
    if (elements.refreshBtn) {
        elements.refreshBtn.addEventListener('click', () => {
            elements.refreshBtn.classList.add('refreshing');
            try {
                updateDashboard(DEMO_DATA);
            } finally {
                elements.refreshBtn.classList.remove('refreshing');
            }
        });
    }

    // Chart view buttons
    elements.chartBtns.forEach(btn => {
        btn.addEventListener('click', () => setChartView(btn.dataset.view));
    });

    // Config toggle
    elements.toggleConfig.addEventListener('click', toggleConfigVisibility);

    // Copy config
    elements.copyConfig.addEventListener('click', copyConfig);
}

// Auto-refresh removed: template is server-rendered and not expected to poll for updates.

// Initialize Application
function init() {
    initTheme();
    initEventListeners();
    // Render once from DEMO_DATA provided by server (or fallback in config.js)
    updateDashboard(DEMO_DATA);
}

// Start the app when DOM is ready
if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
} else {
    init();
}
