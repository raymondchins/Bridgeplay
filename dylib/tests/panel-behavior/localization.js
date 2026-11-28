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
      assert(nodes.some(n => n.props.label === t('Performance Overlay', '性能叠加层', 'Overlay prestazioni', 'Оверлей производительности')));
      assert(nodes.some(n => n.props.label === t('FPS Limit',
        '帧率限制', 'Limite FPS', 'Ограничение FPS')));
      assert(nodes.some(n => n.props.label === t('Scaling Filter',
        '缩放滤镜',
        'Filtro di scala', 'Фильтр масштабирования')));
      assert.deepEqual(dropdowns[2].props.rgOptions.map(o => o.label), [
        t('Automatic (sharp with High Resolution off)', '自动（关闭高分辨率时保持锐利）',
          'Automatico (nitido con Alta risoluzione disattivata)', 'Авто (чётко при выключенном высоком разрешении)'),
        t('Linear (smooth)', '线性（平滑）', 'Lineare (morbido)', 'Линейный (плавный)'),
        t('Nearest (sharp pixels at any scale)', '最近邻（任何比例都保持锐利像素）', 'Nearest (pixel nitidi a qualsiasi scala)', 'Ближайший (чёткие пиксели при любом масштабе)'),
        t('Integer (sharp at exact 2x or 3x, smooth otherwise)', '整数（正好 2 倍或 3 倍时锐利，其他比例平滑）',
          'Intero (nitido a 2x o 3x esatti, morbido altrimenti)', 'Целочисленный (чёткий ровно при 2x или 3x, иначе плавный)')]);
      // The limit is a slider in FPS, which needs no words, and its switch, which does
      assert(nodes.some(n => n.type === 'Slider' && n.props.valueSuffix === ' FPS'));
      assert(nodes.some(n => n.type === 'Toggle' &&
        n.props.label === t('Enable', '启用', 'Attiva', 'Включить')));
      assert.deepEqual(dropdowns[1].props.rgOptions.map(o => o.label), [t('Off', '关闭', 'Disattivato', 'Выкл.'), 'FPS',
        t('Summary', '摘要', 'Riepilogo', 'Сводка'),
        t('Detailed', '详细', 'Dettagliato', 'Подробно'),
        t('Metal HUD', 'Metal 性能监视器', 'Metal HUD', 'Metal HUD')]);
      assert.deepEqual(dropdowns[0].props.rgOptions.map(o => o.data),
        ['', 'd3dmetal', 'dxmt', 'dxvk', 'wined3d']);
      assert(nodes.some(n => n.props.label === t('Graphics', '图形', 'Grafica', 'Графика')));
      assert(nodes.some(n => n.props.label === t('Controllers', '控制器', 'Controller', 'Контроллеры')));
      const raw = nodes.find(n => n.props.label === t('Direct input', '直接输入', 'Input diretto', 'Прямой ввод'));
      assert(nodes.some(n => n.props.label === t('Disable hidraw', '停用 hidraw', 'Disattiva hidraw', 'Отключить hidraw')));
      raw.props.onChange(true);
      assert.equal(written.at(-1).opts, 'BRIDGEPLAY_RAW_CONTROLLERS=1 CX_GRAPHICS_BACKEND=dxmt %command%');
      dropdowns[1].props.onChange({ data: 'hud' });
      assert.equal(written.at(-1).opts, 'MTL_HUD_ENABLED=1 CX_GRAPHICS_BACKEND=dxmt %command%');
      // A native Mac game gets its own panel, in the same four languages.
      const nat = walk(render({ details: details('', { vecPlatforms: ['osx'], strCompatToolName: '' }) }));
      const label = l => nat.find(n => n.props.label === l);
      assert(label(t('Performance Overlay',
        '性能叠加层',
        'Overlay prestazioni', 'Оверлей производительности')));
      assert(label(t('Enable', '启用', 'Attiva', 'Включить')));
      assert(label(t('Frame Generation', '帧生成',
        'Generazione fotogrammi', 'Генерация кадров')));
      assert.deepEqual(label(t('Mode', '模式', 'Modalità', 'Режим')).props.rgOptions.map(o => o.label),
        [t('Off', '关闭', 'Disattivato', 'Выкл.'), '2x', '3x', t('Adaptive (fills to display refresh)',
          '自适应（补足到显示器刷新率）', 'Adattiva (arriva alla frequenza dello schermo)', 'Адаптивный (добирает до частоты обновления дисплея)')]);
      assert.equal(label(t('Scaling Filter',
        '缩放滤镜',
        'Filtro di scala', 'Фильтр масштабирования'))
        .props.children.at(-1).props.rgOptions[0].label,
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
