'use strict';
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { panel, walk, details, FORMS } = require('./harness');

const emit = process.argv[2];
if (!emit) throw new Error('usage: localization.js <emit>');
const doc = lang => ({ document: { documentElement: { lang } } });
const zhCases = [doc('zh-CN'), doc('zh-Hans'), doc('zh_Hans_CN'), doc('zh-SG'), doc('schinese'),
  { navigator: { language: 'zh-CN' } }, { ...doc(''), navigator: { language: 'zh-CN' } }];
const itCases = [doc('it'), doc('it-IT'), doc('it_CH'), doc('italian'),
  { navigator: { language: 'it-IT' } }, { ...doc(''), navigator: { language: 'it' } }];
const ruCases = [doc('ru'), doc('ru-RU'), doc('ru_RU'), doc('russian'),
  { navigator: { language: 'ru-RU' } }, { ...doc(''), navigator: { language: 'ru' } }];
const enCases = [doc('en'), doc('fr'), doc('zh-Hant'), doc('zh-TW'), doc('tchinese'), doc('ita'), doc('iw'), doc('rus'), {},
  { ...doc('en'), navigator: { language: 'zh-CN' } }, { ...doc('en'), navigator: { language: 'it-IT' } },
  { ...doc('en'), navigator: { language: 'ru-RU' } }];
// The same label in English, Chinese, Italian and Russian; t() picks the one for the locale under test.
const lang = { en: 0, zh: 1, it: 2, ru: 3 };

for (const form of Object.keys(FORMS)) {
  for (const [language, cases] of [['zh', zhCases], ['it', itCases], ['ru', ruCases], ['en', enCases]]) {
    const t = (...labels) => labels[lang[language]];
    for (const globals of cases) {
      const { render, written } = panel(emit, form, globals);
      const nodes = walk(render({ details: details('CX_GRAPHICS_BACKEND=dxmt %command%') }));
      const dropdowns = nodes.filter(n => n.type === 'Dropdown');
      assert.equal(dropdowns[0].props.rgOptions[0].label, t('Automatic', '自动', 'Automatico', 'Автоматически'));
      assert.equal(dropdowns[1].props.rgOptions[0].label, t('Off', '关闭', 'Disattivato', 'Выкл.'));
      assert(nodes.some(n => n.props.label === t('Performance Overlay (In game, ⌥⌘P opens quick settings for these controls)', '性能叠加层（游戏中按 ⌥⌘P 打开这些设置的快捷面板）', 'Overlay delle prestazioni (in gioco, ⌥⌘P apre le impostazioni rapide di questi controlli)', 'Оверлей производительности (в игре ⌥⌘P открывает быстрые настройки для этих параметров)')));
      assert(nodes.some(n => n.props.label === t('Frame Rate Limit (Paced to the display. Its refresh rate stays as it is)',
        '帧率限制（与显示器同步，不会更改其刷新率）', 'Limite di fotogrammi (sincronizzato con il display, la cui frequenza non cambia)', 'Ограничение частоты кадров (синхронизировано с дисплеем, его частота обновления не меняется)')));
      assert(nodes.some(n => n.props.label === t('Scaling Filter (When the game draws fewer pixels than the screen, as with High Resolution off)',
        '缩放过滤（当游戏绘制的像素少于屏幕时生效，例如关闭高分辨率时）',
        'Filtro di scala (quando il gioco disegna meno pixel dello schermo, come con Alta risoluzione disattivata)', 'Фильтр масштабирования (когда игра рисует меньше пикселей, чем у экрана, например при выключенном высоком разрешении)')));
      assert.deepEqual(dropdowns[2].props.rgOptions.map(o => o.label), [
        t('Automatic (Wine keeps pixels sharp with High Resolution off)', '自动（关闭高分辨率时 Wine 保持像素锐利）',
          'Automatico (con Alta risoluzione disattivata Wine mantiene i pixel nitidi)', 'Автоматически (при выключенном высоком разрешении Wine сохраняет пиксели чёткими)'),
        t('Linear (smooth)', '线性（平滑）', 'Lineare (morbido)', 'Линейный (плавный)'),
        t('Nearest (sharp pixels at any scale)', '最近邻（任何比例都保持锐利像素）', 'Nearest (pixel nitidi a qualsiasi scala)', 'Ближайший (чёткие пиксели при любом масштабе)'),
        t('Integer (sharp at exact 2x or 3x, smooth otherwise)', '整数（正好 2 倍或 3 倍时锐利，其他比例平滑）',
          'Intero (nitido a 2x o 3x esatti, morbido altrimenti)', 'Целочисленный (чёткий ровно при 2x или 3x, иначе плавный)')]);
      // The limit is a slider in FPS, which needs no words, and its switch, which does
      assert(nodes.some(n => n.type === 'Slider' && n.props.valueSuffix === ' FPS'));
      assert(nodes.some(n => n.type === 'Toggle' &&
        n.props.label === t('Enable frame limit', '启用帧率限制', 'Attiva limite di fotogrammi', 'Включить ограничение частоты кадров')));
      assert.deepEqual(dropdowns[1].props.rgOptions.map(o => o.label), [t('Off', '关闭', 'Disattivato', 'Выкл.'), 'FPS',
        t('Summary (FPS, frame time, CPU, GPU, memory, battery)', '摘要（FPS、帧时间、CPU、GPU、内存、电池）',
          'Riepilogo (FPS, tempo per fotogramma, CPU, GPU, memoria, batteria)', 'Сводка (FPS, время кадра, CPU, GPU, память, аккумулятор)'),
        t('Detailed (adds a frame-time graph)', '详细（增加帧时间图表）', 'Dettagliato (aggiunge il grafico dei tempi per fotogramma)', 'Подробно (добавляет график времени кадра)'),
        t('Apple Metal HUD', 'Apple Metal 性能监视器', 'Metal HUD di Apple', 'Apple Metal HUD')]);
      assert.deepEqual(dropdowns[0].props.rgOptions.map(o => o.data),
        ['', 'd3dmetal', 'dxmt', 'dxvk', 'wined3d']);
      assert(nodes.some(n => n.props.label === t('Graphics', '图形', 'Grafica', 'Графика')));
      assert(nodes.some(n => n.props.label === t('Controllers', '控制器', 'Controller', 'Контроллеры')));
      const raw = nodes.find(n => n.props.label === t(
        'Let games read controllers directly (Recommended on Mac. Turn off only for Steam Input remapping)',
        '允许游戏直接读取控制器（Mac 上推荐，仅在需要 Steam Input 按键映射时关闭）',
        'Lascia che i giochi leggano direttamente i controller (consigliato su Mac, disattiva solo per la rimappatura di Steam Input)', 'Разрешить играм напрямую читать данные геймпадов (рекомендуется на Mac; отключайте только для переназначения кнопок через Steam Input)'));
      assert(nodes.some(n => n.props.label === t('Disable hidraw', '停用 hidraw', 'Disattiva hidraw', 'Отключить hidraw')));
      raw.props.onChange(true);
      assert.equal(written.at(-1).opts, 'BRIDGEPLAY_RAW_CONTROLLERS=1 CX_GRAPHICS_BACKEND=dxmt %command%');
      dropdowns[1].props.onChange({ data: 'hud' });
      assert.equal(written.at(-1).opts, 'MTL_HUD_ENABLED=1 CX_GRAPHICS_BACKEND=dxmt %command%');
      // A native Mac game gets its own panel, in the same four languages.
      const nat = walk(render({ details: details('', { vecPlatforms: ['osx'], strCompatToolName: '' }) }));
      const label = l => nat.find(n => n.props.label === l);
      assert(label(t('Performance Overlay (In game, ⌥⌘P opens quick settings for these controls)',
        '性能叠加层（游戏中按 ⌥⌘P 打开这些设置的快捷面板）',
        'Overlay delle prestazioni (in gioco, ⌥⌘P apre le impostazioni rapide di questi controlli)', 'Оверлей производительности (в игре ⌥⌘P открывает быстрые настройки для этих параметров)')));
      assert(label(t('Enable frame limit', '启用帧率限制', 'Attiva limite di fotogrammi', 'Включить ограничение частоты кадров')));
      assert(label(t('Frame Generation (Experimental. Adds input lag)', '帧生成（实验性。会增加输入延迟）',
        'Generazione fotogrammi (sperimentale. Aggiunge input lag)', 'Генерация кадров (экспериментально, увеличивает задержку ввода)')));
      assert.deepEqual(label(t('Mode', '模式', 'Modalità', 'Режим')).props.rgOptions.map(o => o.label),
        [t('Off', '关闭', 'Disattivato', 'Выкл.'), '2x', '3x', t('Adaptive (fills to display refresh)',
          '自适应（补足到显示器刷新率）', 'Adattiva (arriva alla frequenza dello schermo)', 'Адаптивный (добирает до частоты обновления дисплея)')]);
      assert.equal(label(t('Scaling Filter (When the game draws fewer pixels than the screen, as with High Resolution off)',
        '缩放过滤（当游戏绘制的像素少于屏幕时生效，例如关闭高分辨率时）',
        'Filtro di scala (quando il gioco disegna meno pixel dello schermo, come con Alta risoluzione disattivata)', 'Фильтр масштабирования (когда игра рисует меньше пикселей, чем у экрана, например при выключенном высоком разрешении)'))
        .props.children.props.rgOptions[0].label,
        t('Automatic (as the game sets it)', '自动（沿用游戏的设置）', 'Automatico (come lo imposta il gioco)', 'Автоматически (как задано в игре)'));
      assert(label(t('Controllers', '控制器', 'Controller', 'Контроллеры')));
      assert.deepEqual(label(t('Controller layer', '控制器层', 'Livello controller', 'Слой контроллера')).props.rgOptions.map(o => [o.data, o.label]),
        [['', t('Automatic', '自动', 'Automatico', 'Автоматически')],
         ['hid', t('Raw HID (Unity, SDL, Unreal)', 'Raw HID（Unity、SDL、Unreal）', 'Raw HID (Unity, SDL, Unreal)', 'Raw HID (Unity, SDL, Unreal)')],
         ['gc', 'GameController'], ['off', t('Off', '关闭', 'Disattivato', 'Выкл.')]]);
      for (const [mode, ...labels] of [
        ['compat-hint', 'Enable CrossOver under Properties › Bridgeplay to install and run the Windows version.',
          '请在“属性 › Bridgeplay”中启用 CrossOver，以安装并运行 Windows 版本。',
          'Abilita CrossOver in Proprietà › Bridgeplay per installare e avviare la versione Windows.',
          'Включите CrossOver в разделе «Свойства › Bridgeplay», чтобы установить и запустить версию для Windows.'],
        ['image-files-label', 'Image Files (*.tga,*.png,*.exe)', '图像文件 (*.tga,*.png,*.exe)',
          'File immagine (*.tga,*.png,*.exe)',
          'Файлы изображений (*.tga,*.png,*.exe)'],
        ['library-windows-hint', 'Show only games that run on Windows and do not have a macOS version',
          '仅显示可在 Windows 上运行且没有 macOS 版本的游戏',
          'Mostra solo i giochi che funzionano su Windows e non hanno una versione macOS',
          'Показывать только игры, которые работают в Windows и не имеют версии для macOS'],
        ['library-windows-summary', 'Runs on Windows, no macOS version', '可在 Windows 上运行，无 macOS 版本',
          'Funziona su Windows, nessuna versione macOS',
          'Работает в Windows, версии для macOS нет'],
      ]) {
        const src = execFileSync(emit, [mode], { encoding: 'utf8' });
        assert.equal(new Function('globalThis', `return ${src}`)(globals), t(...labels));
      }
    }
  }
}
console.log('PASS: both panel shapes, Chinese/Italian/Russian/English locales, fallback, labels and unchanged option values');
