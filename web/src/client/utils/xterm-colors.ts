// XTerm 256-color palette generator
export function generateXTermColorCSS(): string {
  const colors: string[] = [];

  // Standard 16 colors (0-15)
  const standard16 = [
    '#000000',
    '#800000',
    '#008000',
    '#808000',
    '#000080',
    '#800080',
    '#008080',
    '#c0c0c0',
    '#808080',
    '#ff0000',
    '#00ff00',
    '#ffff00',
    '#0000ff',
    '#ff00ff',
    '#00ffff',
    '#ffffff',
  ];

  standard16.forEach((color, i) => {
    colors.push(`  --terminal-color-${i}: ${color};`);
  });

  // 216 color cube (16-231)
  const cube = [0, 95, 135, 175, 215, 255];
  for (let r = 0; r < 6; r++) {
    for (let g = 0; g < 6; g++) {
      for (let b = 0; b < 6; b++) {
        const index = 16 + r * 36 + g * 6 + b;
        const red = cube[r].toString(16).padStart(2, '0');
        const green = cube[g].toString(16).padStart(2, '0');
        const blue = cube[b].toString(16).padStart(2, '0');
        colors.push(`  --terminal-color-${index}: #${red}${green}${blue};`);
      }
    }
  }

  // Grayscale (232-255)
  for (let i = 0; i < 24; i++) {
    const gray = Math.round(8 + i * 10);
    const hex = gray.toString(16).padStart(2, '0');
    colors.push(`  --terminal-color-${232 + i}: #${hex}${hex}${hex};`);
  }

  return `:root {\n${colors.join('\n')}\n}`;
}
