// lib/translations.dart

/// مدیریت جامع چندزبانه‌سازی و دیکشنری متون نرم‌افزار RedCloud VPN
class AppTranslations {
  /// زبان فعال نرم‌افزار ('fa' یا 'en')
  static String currentLang = 'fa';

  /// بررسی اینکه آیا جهت چیدمان راست‌به‌چپ (RTL) است یا خیر
  static bool get isRtl => currentLang == 'fa';

  /// دریافت ترجمه یک کلید متنی با قابلیت جای‌گذاری متغیرها
  static String tr(String key, {Map<String, String>? params}) {
    String value = _translations[currentLang]?[key] ??
        _translations['en']?[key] ??
        _translations['fa']?[key] ??
        key;

    if (params != null) {
      params.forEach((paramKey, paramValue) {
        value = value.replaceAll('{$paramKey}', paramValue);
      });
    }
    return value;
  }

  /// مخزن کامل ترجمه‌ها
  static final Map<String, Map<String, String>> _translations = {
    // =========================================================================
    // دیکشنری زبان فارسی (FA)
    // =========================================================================
    'fa': {
      // عمومی و برند
      'app_name': 'RedCloud',
      'app_subtitle': 'Next-Gen Anti-Censorship Client',
      'app_edition': 'نسخه ضدسانسور {version} (Hybrid)',
      'close': 'بستن',
      'cancel': 'انصراف',
      'save': 'ذخیره',
      'save_changes': 'ذخیره تغییرات',
      'edit': 'ویرایش',
      'delete': 'حذف',
      'copy': 'کپی',
      'status_ready': 'سیستم آماده اتصال است',
      'status_disconnected': 'قطع اتصال',
      'telegram': 'تلگرام',
      'donate': 'حمایت',
      'check_update': 'بررسی آپدیت نرم‌افزار',
      'checking_update': 'بررسی...',
      'update_available': 'آپدیت نسخه {version} آماده است',
      'already_latest_version': 'شما از آخرین نسخه برنامه (v{version}) استفاده می‌کنید.',
      'unknown': 'ناشناس',
      'fetching_ip': 'در حال دریافت آی‌پی...',
      'querying_location': 'در حال استعلام هویت و موقعیت جغرافیایی سرور...',

      // پنجره اولین اجرا (Language Setup)
      'welcome_title': 'خوش آمدید به RedCloud VPN',
      'welcome_subtitle': 'لطفاً زبان رابط کاربری برنامه را انتخاب کنید:\nPlease select your preferred language:',
      'lang_persian': 'فارسی (Persian)',
      'lang_english': 'English (انگلیسی)',
      'start_app': 'ورود به برنامه',

      // سایدبار (منو)
      'menu_dashboard': 'داشبورد ویتوری',
      'menu_aether': 'شبکه اِتر (MASQUE)',
      'menu_configs': 'پیکربندی و سرورها',
      'menu_tor': 'شبکه پیاز تور (Tor)',
      'menu_psiphon': 'شبکه سایفون (Psiphon)',
      'menu_scanner': 'اسکنر کلودفلر',
      'menu_dns': 'تغییر دهنده DNS',
      'menu_lan': 'اشتراک‌گذاری LAN و QR',
      'menu_settings': 'تنظیمات برنامه',
      'menu_help': 'راهنمای جامع کاربری',
      'menu_anti_dpi': 'تنظیمات Anti-DPI',

      // داشبورد
      'dash_title': 'داشبورد ویتوری و اتصال هیبریدی',
      'dash_subtitle': 'کنترل ترافیک با قابلیت زنجیره‌سازی خودکار از دل پل ضدسانسور اِتر',
      'hybrid_mode': 'اتصال هیبریدی:',
      'goodbyedpi_effect': 'افکت ضد DPI (GoodbyeDPI):',
      'tap_to_connect_hybrid': 'جهت اتصال هیبریدی ضربه بزنید',
      'tap_to_connect_direct': 'جهت اتصال ویتوری مستقیم ضربه بزنید',
      'connected_hybrid': 'متصل به اتصال هیبریدی (پل اِتر + Sing-box)',
      'connected_direct': 'متصل به ویتوری مستقیم',
      'download': 'دانلود',
      'upload': 'آپلود',
      'sys_proxy_title': 'تنظیم اتوماتیک پروکسی سیستم‌عامل',
      'sys_proxy_sub': 'فعال‌سازی رجیستری ویندوز جهت عبور کل ترافیک سیستم',
      'tun_title': 'فعال‌سازی کارت شبکه مجازی (TUN Mode)',
      'tun_sub': 'عبور ترافیک کل سیستم (حتی بازی‌ها و برنامه‌های بدون پروکسی)',
      'anti_dpi_box_title': 'تنظیمات پیشرفته ضدسانسور (Anti-DPI)',
      'anti_dpi_box_sub': 'جعل اثر انگشت مرورگر، فرگمنت ترافیک و تزریق اس‌ان‌آی فیک',
      'configure': 'پیکربندی',
      'active_server_outbound': 'سرور فعال برای خروجی ویتوری',
      'auto_github_server': 'سرور خودکار (دریافت اتوماتیک از گیت‌هاب)',
      'toast_ip_copied': 'آی‌پی کپی شد!',

      // صفحه اِتر (Aether)
      'aether_badge': 'پروتکل نسل جدید MASQUE',
      'aether_title': 'شبکه ضدسانسور اِتر (Aether Engine)',
      'aether_subtitle': 'اتصال مستقیم و مقاوم به شبکه Cloudflare Zero Trust بر بستر HTTP/3 QUIC بدون نیاز به دامنه شخصی',
      'aether_connected': 'متصل به شبکه اِتر (MASQUE)',
      'aether_connecting': 'در حال اسکن و تایید عبور داده: {percent}٪',
      'aether_tap_to_connect': 'جهت اتصال به شبکه اِتر ضربه بزنید',
      'aether_mode_label': 'حالت پروتکل ضدسانسور (Mode):',
      'aether_noise_label': 'پروفایل پارازیت ضد DPI (Noize):',
      'aether_adv_title': 'تنظیمات پیشرفته (اکانت WARP+ و Zero Trust)',
      'aether_warp_key': 'کلید لایسنس WARP+ (اختیاری)',
      'aether_warp_hint': 'لایسنس ۲۴ کاراکتری وارپ پلاس',
      'aether_team_token': 'نام سازمان یا توکن Team کلودفلر (اختیاری)',
      'aether_team_hint': 'مثلاً myteam.cloudflarewarp.com',
      'aether_sys_proxy': 'تنظیم اتوماتیک پروکسی سیستم‌عامل (HTTP 1820 & SOCKS 1819)',
      'aether_sys_proxy_sub': 'هدایت خودکار ترافیک کروم و ویندوز به درگاه Aether',
      'aether_live_status': 'وضعیت زنده اسکنر Data-Plane اتر:',

      // صفحه سرورها و کانفیگ
      'configs_title': 'مدیریت پیشرفته سرورها و ساب‌اسکریپشن',
      'configs_subtitle': 'دسته‌بندی گروه‌های ساب، بروزرسانی خودکار، فیلتر آنی و تست پینگ فوق‌سریع',
      'add_single_config': 'افزودن کانفیگ تکی',
      'add_new_sub': 'افزودن ساب جدید',
      'tab_all_servers': 'همه سرورها',
      'tab_manual_scanner': 'دستی و اسکنر',
      'search_placeholder': 'جستجوی سرور بر اساس نام، پورت، آی‌پی، پروتکل...',
      'update_all_subs': 'بروزرسانی ساب‌ها',
      'ping_and_sort': 'تست پینگ و مرتب‌سازی',
      'pinging_in_progress': 'در حال پایش...',
      'clean_dead_nodes': 'حذف سرورهای قطع (Timeout)',
      'no_servers_found': 'سروری در این دسته یافت نشد.',
      'copied_config_link': 'لینک کانفیگ با موفقیت کپی شد!',

      // صفحه تور (Tor)
      'tor_title': 'شبکه پیاز تور (Tor Network)',
      'tor_subtitle': 'اتصال فوق‌امن و گمنام با امکان گذر از گارد ضدسانسور MASQUE و تعیین کشور خروجی',
      'tor_over_masque': 'پل مسک (Tor over MASQUE):',
      'tor_connected_masque': 'متصل به شبکه تور بر بستر مسک (MASQUE)',
      'tor_connected_direct': 'متصل به شبکه پیاز تور',
      'tor_connecting': 'در حال برقراری مدار پیاز: {percent}٪',
      'tor_tap_connect_masque': 'جهت اتصال تور از بستر مسک ضربه بزنید',
      'tor_tap_connect_direct': 'جهت اتصال به تور مستقیم ضربه بزنید',
      'exit_node_country': 'کشور خروجی (Exit Node):',
      'tor_sys_proxy': 'تنظیم اتوماتیک پروکسی سیستم‌عامل (Port 9051)',

      // صفحه سایفون (Psiphon)
      'psiphon_title': 'شبکه سایفون (Psiphon Network)',
      'psiphon_subtitle': 'اتصال امن به فیلترشکن سایفون با امکان گذر از بستر پرسرعت و پایدار MASQUE',
      'psiphon_over_masque': 'پل مسک (Psiphon over MASQUE):',
      'psiphon_connected_masque': 'متصل به سایفون بر بستر مسک (MASQUE)',
      'psiphon_connected_direct': 'متصل به سایفون مستقیم',
      'psiphon_connecting_masque': 'در حال برقراری پل مسک و تونل سایفون...',
      'psiphon_connecting_direct': 'در حال اتصال به سرورهای سایفون...',
      'psiphon_tap_connect_masque': 'جهت اتصال سایفون از بستر مسک ضربه بزنید',
      'psiphon_tap_connect_direct': 'جهت اتصال به سایفون مستقیم ضربه بزنید',
      'psiphon_sys_proxy': 'تنظیم اتوماتیک پروکسی سیستم‌عامل (Port 9081)',

      // اسکنر کلودفلر
      'scanner_title': 'اسکنر موازی کلودفلر (IP Scanner)',
      'scanner_subtitle': 'اسکن دو‌حالته سریع و عمیق با پایش زنده TCP Ping و TLS Handshake',
      'fetch_github_accounts': 'دریافت اطلاعات اکانت از گیت‌هاب:',
      'fetch_random_accounts': 'دریافت اکانت‌های رندوم',
      'account_uuid': 'کلید شناسایی کاربر (UUID)',
      'account_worker': 'دامنه ورکر (Worker Domain)',
      'account_path': 'مسیر کانفیگ (WebSocket Path)',
      'stat_total': 'کل بررسی‌شده',
      'stat_alive': 'آی‌پی‌های سالم',
      'stat_dead': 'مسدود / تایم‌اوت',
      'quick_scan': 'اسکن سریع',
      'deep_scan': 'اسکن عمیق (Deep Scan)',
      'stop_scan': 'توقف اسکن',
      'scanner_status_logs': 'وضعیت و لاگ‌های اسکنر:',

      // تغییر دهنده DNS
      'dns_title': 'تغییر دهنده هوشمند DNS',
      'dns_subtitle': 'اعمال دی‌ان‌اس‌های تحریم‌شکن با بررسی زنده پینگ و تاخیر شبکه',
      'dns_active': 'دی‌ان‌اس فعال است',
      'dns_tap_to_apply': 'جهت اعمال دی‌ان‌اس ضربه بزنید',
      'dns_select': 'انتخاب DNS:',
      'dns_add_custom': 'افزودن DNS',
      'dns_primary': 'سرور اولیه (Primary):',
      'dns_secondary': 'سرور ثانویه (Secondary):',
      'dns_doh_url': 'آدرس رمزنگاری DoH:',
      'dns_dot_host': 'هاست امن DoT:',
      'dns_latency': 'تاخیر پاسخگویی (Ping):',
      'dns_delete_custom': 'حذف این دی‌ان‌اس سفارشی',

      // اشتراک‌گذاری LAN
      'lan_title': 'اشتراک‌گذاری اینترنت در شبکه محلی (LAN Share)',
      'lan_subtitle': 'تبدیل سیستم به گذرگاه پروکسی خانگی و اتصال گوشی، تلویزیون و کنسول با QR Code',
      'lan_status': 'وضعیت اشتراک‌گذاری:',
      'lan_active_qr': 'پروکسی فعال است! بارکد را اسکن کنید',
      'lan_disabled_qr': 'اشتراک‌گذاری خاموش است (سوییچ بالا را روشن کنید)',
      'lan_local_ip_label': 'آدرس شبکه محلی: {ip}:{port}',
      'lan_proxy_specs': 'مشخصات اتصال پروکسی محلی',
      'lan_host_label': 'آی‌پی محلی سیستم (Proxy Host):',
      'lan_port_label': 'پورت LAN',
      'copy_ipport': 'کپی IP:Port',
      'copy_tg_proxy': 'کپی پروکسی تلگرام',
      'copied_ipport_toast': 'آدرس IP:Port کپی شد!',
      'copied_tg_toast': 'لینک اتصال پروکسی تلگرام کپی شد!',

      // تنظیمات برنامه (Settings)
      'settings_title': 'تنظیمات برنامه',
      'settings_subtitle': 'پیکربندی هسته‌های سیستم، مسیر باینری‌ها و دریافت گزارش جامع خطاها',
      'language_section_title': 'انتخاب زبان برنامه (Application Language)',
      'language_section_sub': 'تغییر زبان محیط کاربری و جهت نوشتاری نرم‌افزار',
      'logs_title': 'گزارش خطاها و عیب‌یابی (Crash & Error Log)',
      'logs_sub': 'مشاهده و ارسال فایل log.txt جهت بررسی و حل مشکلات برنامه',
      'logs_desc': 'تمامی وقایع برنامه از جمله خطاهای اتصال، پروسه‌های پس‌زمینه و کرش‌ها به‌صورت خودکار در فایل log.txt ثبت می‌شوند. با زدن دکمه زیر می‌توانید پوشه این فایل را در ویندوز باز کرده و آن را برای تیم توسعه ارسال کنید.',
      'btn_open_log_dir': 'باز کردن پوشه و مشاهده فایل log.txt',
      'btn_copy_log_path': 'کپی مسیر فایل',
      'btn_clear_log': 'پاکسازی لاگ',
      'goodbyedpi_path_label': 'مسیر فایل goodbyedpi.exe',
      'aether_path_label': 'مسیر فایل هسته aether.exe',
      'singbox_path_label': 'مسیر فایل هسته sing-box.exe',
      'tor_path_label': 'مسیر فایل هسته tor.exe',
      'psiphon_path_label': 'مسیر فایل هسته psiphon-tunnel-core.exe',
      'target_os_label': 'سیستم‌عامل مقصد فعلی: Windows',

      // دیالوگ حمایت مالی
      'donation_title': 'حمایت مالی از پروژه RedCloud',
      'donation_desc': 'از اینکه با حمایت مالی خود به توسعه، بقا و ارتقای سرورهای ضدسانسور RedCloud کمک می‌کنید، بی‌نهایت سپاسگزاریم.\nحمایت‌های ارزشمند شما انگیزه اصلی ما برای مبارزه با فیلترینگ و حفظ اینترنت آزاد برای همه است. ❤️',
      'usdt_label': 'آدرس تتر (USDT)',
      'bep20_network': 'شبکه BNB Smart Chain (BEP20)',
      'btn_copy_wallet': 'کپی آدرس ولت',
      'copied_wallet_toast': 'آدرس ولت با موفقیت کپی شد! تشکر از حمایت شما ❤️',

      // دیالوگ پیکربندی GoodbyeDPI
      'gdpi_dialog_title': 'پیکربندی افکت ضد DPI (GoodbyeDPI)',
      'gdpi_dialog_desc': 'هسته GoodbyeDPI بدون تغییر پروکسی، در سطح کرنل و کارت شبکه پکت‌ها را دستکاری و فرگمنت می‌کند تا از سد فیلترینگ DPI عبور کند.',
      'gdpi_preset_label': 'انتخاب پریست (Preset):',
      'gdpi_cli_label': 'آرگومان‌های خط فرمان (CLI Arguments)',
      'gdpi_saved_toast': 'تنظیمات GoodbyeDPI با موفقیت ذخیره شد.',

      // صفحه تنظیمات Anti-DPI
      'anti_dpi_page_title': 'تنظیمات فوق پیشرفته ضدسانسور (Anti-DPI)',
      'anti_dpi_page_sub': 'تکنیک‌های جعل دست‌دهی TLS، قطعه‌بندی ترافیک و افکت GoodbyeDPI',
      'anti_dpi_btn_save': 'ثبت و اعمال تنظیمات ضدسانسور',
      'anti_dpi_saved_toast': 'تنظیمات پیشرفته Anti-DPI با موفقیت اعمال شد.',
    },

    // =========================================================================
    // دیکشنری زبان انگلیسی (EN)
    // =========================================================================
    'en': {
      // General & Brand
      'app_name': 'RedCloud',
      'app_subtitle': 'Next-Gen Anti-Censorship Client',
      'app_edition': 'Anti-Censorship Edition {version} (Hybrid)',
      'close': 'Close',
      'cancel': 'Cancel',
      'save': 'Save',
      'save_changes': 'Save Changes',
      'edit': 'Edit',
      'delete': 'Delete',
      'copy': 'Copy',
      'status_ready': 'System is ready to connect',
      'status_disconnected': 'Disconnected',
      'telegram': 'Telegram',
      'donate': 'Donate',
      'check_update': 'Check for Updates',
      'checking_update': 'Checking...',
      'update_available': 'Update v{version} is available',
      'already_latest_version': 'You are using the latest version (v{version}).',
      'unknown': 'Unknown',
      'fetching_ip': 'Fetching IP info...',
      'querying_location': 'Querying server location and IP identity...',

      // First Launch Language Setup
      'welcome_title': 'Welcome to RedCloud VPN',
      'welcome_subtitle': 'Please select your preferred language:\nلطفاً زبان مورد نظر خود را انتخاب کنید:',
      'lang_persian': 'فارسی (Persian)',
      'lang_english': 'English',
      'start_app': 'Start Application',

      // Sidebar (Menu)
      'menu_dashboard': 'V2Ray Dashboard',
      'menu_aether': 'Aether Network (MASQUE)',
      'menu_configs': 'Config & Servers',
      'menu_tor': 'Tor Onion Network',
      'menu_psiphon': 'Psiphon Network',
      'menu_scanner': 'Cloudflare Scanner',
      'menu_dns': 'DNS Changer',
      'menu_lan': 'LAN Share & QR',
      'menu_settings': 'Settings',
      'menu_help': 'User Guide',
      'menu_anti_dpi': 'Anti-DPI Settings',

      // Dashboard
      'dash_title': 'V2Ray & Hybrid Dashboard',
      'dash_subtitle': 'Intelligent traffic chaining routed through Aether MASQUE anti-censorship bridge',
      'hybrid_mode': 'Hybrid Connection:',
      'goodbyedpi_effect': 'Anti-DPI Effect (GoodbyeDPI):',
      'tap_to_connect_hybrid': 'Tap to connect (Hybrid)',
      'tap_to_connect_direct': 'Tap to connect (Direct V2Ray)',
      'connected_hybrid': 'Connected to Hybrid Tunnel (Aether + Sing-box)',
      'connected_direct': 'Connected to Direct V2Ray',
      'download': 'Download',
      'upload': 'Upload',
      'sys_proxy_title': 'Automatic System Proxy',
      'sys_proxy_sub': 'Configures Windows registry to route all system traffic',
      'tun_title': 'Virtual TUN Adapter (TUN Mode)',
      'tun_sub': 'Route entire system traffic (including games and non-proxy apps)',
      'anti_dpi_box_title': 'Advanced Anti-DPI Settings',
      'anti_dpi_box_sub': 'uTLS fingerprinting, packet fragmentation, and fake SNI spoofing',
      'configure': 'Configure',
      'active_server_outbound': 'Active Server for V2Ray Outbound',
      'auto_github_server': 'Auto Server (Auto-fetched from GitHub)',
      'toast_ip_copied': 'IP address copied to clipboard!',

      // Aether Page
      'aether_badge': 'Next-Gen MASQUE Protocol',
      'aether_title': 'Aether Anti-Censorship Engine',
      'aether_subtitle': 'Resilient direct connection to Cloudflare Zero Trust over HTTP/3 QUIC without private domains',
      'aether_connected': 'Connected to Aether Network (MASQUE)',
      'aether_connecting': 'Scanning & validating data path: {percent}%',
      'aether_tap_to_connect': 'Tap to connect to Aether Network',
      'aether_mode_label': 'Anti-Censorship Mode:',
      'aether_noise_label': 'Anti-DPI Noise Profile (Noize):',
      'aether_adv_title': 'Advanced Settings (WARP+ & Zero Trust)',
      'aether_warp_key': 'WARP+ License Key (Optional)',
      'aether_warp_hint': '24-character WARP+ license key',
      'aether_team_token': 'Cloudflare Team domain or token (Optional)',
      'aether_team_hint': 'e.g. myteam.cloudflarewarp.com',
      'aether_sys_proxy': 'Set System Proxy (HTTP 1820 & SOCKS 1819)',
      'aether_sys_proxy_sub': 'Auto-route Windows and browser traffic to Aether gateway',
      'aether_live_status': 'Aether Data-Plane Scanner Live Status:',

      // Configs & Servers Page
      'configs_title': 'Servers & Subscription Management',
      'configs_subtitle': 'Subscription grouping, auto-update, instant search, and ultra-fast ping testing',
      'add_single_config': 'Add Single Config',
      'add_new_sub': 'Add New Subscription',
      'tab_all_servers': 'All Servers',
      'tab_manual_scanner': 'Manual & Scanner',
      'search_placeholder': 'Search servers by name, port, IP, protocol...',
      'update_all_subs': 'Update Subscriptions',
      'ping_and_sort': 'Ping Test & Sort',
      'pinging_in_progress': 'Pinging servers...',
      'clean_dead_nodes': 'Remove Timeout Servers',
      'no_servers_found': 'No servers found in this group.',
      'copied_config_link': 'Config link copied to clipboard!',

      // Tor Page
      'tor_title': 'Tor Onion Network',
      'tor_subtitle': 'Ultra-secure anonymous network with MASQUE guard bypass and custom exit node selection',
      'tor_over_masque': 'Tor over MASQUE Bridge:',
      'tor_connected_masque': 'Connected to Tor over MASQUE Bridge',
      'tor_connected_direct': 'Connected to Tor Network',
      'tor_connecting': 'Bootstrapping onion circuit: {percent}%',
      'tor_tap_connect_masque': 'Tap to connect Tor via MASQUE Bridge',
      'tor_tap_connect_direct': 'Tap to connect to Direct Tor',
      'exit_node_country': 'Exit Node Country:',
      'tor_sys_proxy': 'Set System Proxy Automatically (Port 9051)',

      // Psiphon Page
      'psiphon_title': 'Psiphon Network',
      'psiphon_subtitle': 'Secure Psiphon tunnel with optional high-speed MASQUE bridge routing',
      'psiphon_over_masque': 'Psiphon over MASQUE Bridge:',
      'psiphon_connected_masque': 'Connected to Psiphon over MASQUE Bridge',
      'psiphon_connected_direct': 'Connected to Psiphon Direct',
      'psiphon_connecting_masque': 'Establishing MASQUE bridge & Psiphon tunnel...',
      'psiphon_connecting_direct': 'Connecting to Psiphon servers...',
      'psiphon_tap_connect_masque': 'Tap to connect Psiphon via MASQUE Bridge',
      'psiphon_tap_connect_direct': 'Tap to connect to Direct Psiphon',
      'psiphon_sys_proxy': 'Set System Proxy Automatically (Port 9081)',

      // Scanner Page
      'scanner_title': 'Cloudflare Parallel IP Scanner',
      'scanner_subtitle': 'Dual Quick & Deep scanner with real-time TCP ping and TLS handshake probing',
      'fetch_github_accounts': 'Fetch Accounts from GitHub:',
      'fetch_random_accounts': 'Fetch Random Accounts',
      'account_uuid': 'User Identifier (UUID)',
      'account_worker': 'Worker Domain',
      'account_path': 'WebSocket Path',
      'stat_total': 'Total Scanned',
      'stat_alive': 'Alive IPs',
      'stat_dead': 'Blocked / Timeout',
      'quick_scan': 'Quick Scan',
      'deep_scan': 'Deep Scan',
      'stop_scan': 'Stop Scan',
      'scanner_status_logs': 'Scanner Live Status & Logs:',

      // DNS Changer
      'dns_title': 'Smart DNS Changer',
      'dns_subtitle': 'Bypass regional geo-restrictions with live latency and ping benchmark',
      'dns_active': 'DNS is Active',
      'dns_tap_to_apply': 'Tap to apply DNS to Windows',
      'dns_select': 'Select DNS Profile:',
      'dns_add_custom': 'Add Custom DNS',
      'dns_primary': 'Primary DNS Server:',
      'dns_secondary': 'Secondary DNS Server:',
      'dns_doh_url': 'DoH Encrypted URL:',
      'dns_dot_host': 'DoT Secure Host:',
      'dns_latency': 'Response Latency (Ping):',
      'dns_delete_custom': 'Delete this Custom DNS',

      // LAN Share
      'lan_title': 'Local Area Network Sharing (LAN Share)',
      'lan_subtitle': 'Turn your PC into a home proxy gateway for phones, consoles & TVs via QR Code',
      'lan_status': 'Sharing Status:',
      'lan_active_qr': 'Proxy Active! Scan QR code to connect',
      'lan_disabled_qr': 'Sharing is disabled (Toggle switch above)',
      'lan_local_ip_label': 'Local Network Address: {ip}:{port}',
      'lan_proxy_specs': 'Local Proxy Connection Details',
      'lan_host_label': 'Local System IP (Proxy Host):',
      'lan_port_label': 'LAN Port',
      'copy_ipport': 'Copy IP:Port',
      'copy_tg_proxy': 'Copy Telegram Proxy',
      'copied_ipport_toast': 'IP:Port copied to clipboard!',
      'copied_tg_toast': 'Telegram proxy link copied to clipboard!',

      // Settings
      'settings_title': 'Application Settings',
      'settings_subtitle': 'Core binary configurations, logs, and error diagnostic tools',
      'language_section_title': 'Application Language',
      'language_section_sub': 'Switch UI language and layout direction',
      'logs_title': 'Crash & Diagnostic Logs',
      'logs_sub': 'Inspect and export log.txt for issue troubleshooting',
      'logs_desc': 'All application events, connection attempts, background processes, and crashes are automatically saved to log.txt. Click below to open the log directory and share it with developers.',
      'btn_open_log_dir': 'Open Folder and View log.txt',
      'btn_copy_log_path': 'Copy File Path',
      'btn_clear_log': 'Clear Log File',
      'goodbyedpi_path_label': 'Path to goodbyedpi.exe',
      'aether_path_label': 'Path to aether.exe',
      'singbox_path_label': 'Path to sing-box.exe',
      'tor_path_label': 'Path to tor.exe',
      'psiphon_path_label': 'Path to psiphon-tunnel-core.exe',
      'target_os_label': 'Target Operating System: Windows (x64)',

      // Donation Dialog
      'donation_title': 'Support RedCloud Project',
      'donation_desc': 'Thank you sincerely for supporting the ongoing development and server maintenance of RedCloud.\nYour support is our primary motivation to combat internet censorship and uphold internet freedom for everyone. ❤️',
      'usdt_label': 'USDT Tether Address',
      'bep20_network': 'BNB Smart Chain (BEP20) Network',
      'btn_copy_wallet': 'Copy Wallet Address',
      'copied_wallet_toast': 'Wallet address copied! Thank you for your support ❤️',

      // GoodbyeDPI Dialog
      'gdpi_dialog_title': 'Configure GoodbyeDPI (Anti-DPI Effect)',
      'gdpi_dialog_desc': 'GoodbyeDPI operates at the Windows kernel level (WinDivert) to fragment and modify packets without changing proxy settings to defeat DPI filters.',
      'gdpi_preset_label': 'Select Preset:',
      'gdpi_cli_label': 'Command-line Arguments (CLI)',
      'gdpi_saved_toast': 'GoodbyeDPI settings saved successfully.',

      // Anti-DPI Page
      'anti_dpi_page_title': 'Advanced Anti-Censorship (Anti-DPI)',
      'anti_dpi_page_sub': 'TLS handshake spoofing, traffic fragmentation, and GoodbyeDPI filter bypass',
      'anti_dpi_btn_save': 'Save & Apply Anti-DPI Settings',
      'anti_dpi_saved_toast': 'Anti-DPI settings saved and applied successfully.',
    }
  };
}

/// اکستنشن کاربردی جهت فراخوانی سریع ترجمه در هر کجای کدهای دارت
extension StringTranslateExtension on String {
  String tr({Map<String, String>? params}) {
    return AppTranslations.tr(this, params: params);
  }
}