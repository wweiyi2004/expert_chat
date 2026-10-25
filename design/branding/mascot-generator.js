// 用法：node mascot-generator.js <输出目录>（需要 @resvg/resvg-js 来渲染预览 PNG）
// 生成三个候选图标角色（无描边扁平色块），并渲染多尺寸 PNG 供检查
const fs = require('fs');
const path = require('path');
const { Resvg } = require('@resvg/resvg-js');
const OUT = process.argv[2];

const mirror = d => `<g transform="translate(1024 0) scale(-1 1)">${d}</g>`;

function eyes(c) {
  const white = 'M386 540 Q436 500 490 528 L490 584 Q438 608 388 584 Z';
  const one = `
    <path d="${white}" fill="#FFFFFF"/>
    <g clip-path="url(#sc-${c.id})">
      <ellipse cx="440" cy="560" rx="39" ry="51" fill="${c.iris}"/>
      <g clip-path="url(#ir-${c.id})">
        <ellipse cx="440" cy="522" rx="50" ry="36" fill="${c.irisDark}"/>
        <ellipse cx="440" cy="604" rx="34" ry="20" fill="${c.irisLight}"/>
      </g>
      <ellipse cx="442" cy="564" rx="15" ry="22" fill="${c.pupil}"/>
    </g>
    <path d="M370 542 Q432 482 498 518 Q504 522 506 530 L496 532 Q434 498 380 550 Q366 558 352 554 Q362 550 370 542 Z" fill="${c.lash}"/>
    <path d="M370 542 Q356 532 346 534 Q356 544 366 548 Z" fill="${c.lash}"/>
    <path d="M388 584 Q394 596 408 600" fill="none" stroke="${c.lash}" stroke-width="5" stroke-linecap="round" opacity=".55"/>`;
  const hi = cx => `<ellipse cx="${cx - 16}" cy="538" rx="13" ry="17" fill="#FFFFFF"/><circle cx="${cx + 14}" cy="586" r="6" fill="#FFFFFF" opacity=".9"/>`;
  const big = x => `<g transform="translate(${x} 556) scale(1.1) translate(${-x} -556)">`;
  const defs = `<defs><clipPath id="ir-${c.id}"><ellipse cx="440" cy="560" rx="39" ry="51"/></clipPath><clipPath id="sc-${c.id}"><path d="${white}"/></clipPath></defs>`;
  return defs + big(438) + one + '</g>' + mirror(big(438) + one + '</g>') + big(438) + hi(440) + '</g>' + big(586) + hi(584) + '</g>';
}

function face(c) {
  const shape = 'M330 420 C328 560 374 676 512 734 C650 676 696 560 694 420 C694 330 620 286 512 286 C404 286 330 330 330 420 Z';
  return `
    <path d="M462 690 L462 832 Q512 852 562 832 L562 690 Z" fill="${c.skin}"/>
    <path d="M462 704 Q512 774 562 704 L562 748 Q512 808 462 748 Z" fill="${c.skinShade}"/>
    <path d="${shape}" fill="${c.skin}"/>
    <clipPath id="face-${c.id}"><path d="${shape}"/></clipPath>
    <g clip-path="url(#face-${c.id})"><path d="${c.bangs}" transform="translate(0 13)" fill="${c.skinShade}" opacity=".7"/></g>
    <ellipse cx="392" cy="630" rx="36" ry="17" fill="${c.blush}" opacity=".55"/>
    <ellipse cx="632" cy="630" rx="36" ry="17" fill="${c.blush}" opacity=".55"/>
    <path d="M506 618 Q512 624 518 618" fill="none" stroke="${c.skinShade}" stroke-width="6" stroke-linecap="round"/>
    <path d="M490 652 Q512 680 534 652 Q512 662 490 652 Z" fill="${c.mouth}"/>`;
}

function sparkle(x, y, r, fill, op) {
  return `<path d="M${x} ${y - r} Q${x + r * .18} ${y - r * .18} ${x + r} ${y} Q${x + r * .18} ${y + r * .18} ${x} ${y + r} Q${x - r * .18} ${y + r * .18} ${x - r} ${y} Q${x - r * .18} ${y - r * .18} ${x} ${y - r} Z" fill="${fill}" opacity="${op}"/>`;
}

function icon(c) {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024" role="img" aria-labelledby="t-${c.id}">
<title id="t-${c.id}">${c.title}</title>
<defs><clipPath id="frame-${c.id}"><rect width="1024" height="1024" rx="232"/></clipPath></defs>
<g clip-path="url(#frame-${c.id})">
  <rect width="1024" height="1024" fill="${c.bg}"/>
  <circle cx="512" cy="500" r="408" fill="${c.halo}"/>
  ${sparkle(150, 210, 34, c.spark, .9)}${sparkle(880, 300, 22, c.spark, .75)}${sparkle(860, 820, 16, c.spark, .5)}
  <g transform="translate(512 600) scale(1.12) translate(-512 -600)">
  ${c.back}
  <path d="M232 1024 C240 884 350 822 512 816 C674 822 784 884 792 1024 Z" fill="${c.outfit}"/>
  ${c.collar}
  ${face(c)}
  ${eyes(c)}
  ${c.front}
  </g>
</g>
</svg>`;
}

/* ---------- A 小黛：深蓝短发、耳机、胭脂领结 ---------- */
const bangsA = 'M288 476 C266 300 370 198 512 198 C654 198 758 300 736 476 Q708 452 694 420 Q680 472 652 506 Q642 454 616 430 Q600 476 568 500 Q560 450 534 426 Q518 472 486 508 Q478 452 450 430 Q434 474 404 494 Q396 452 380 434 Q362 468 334 486 Q310 482 288 476 Z';
const A = {
  id: 'a', title: 'Expert Chat · 小黛',
  bg: '#1F6FA3', halo: '#2B82B8', spark: '#D6ECF0',
  skin: '#FDEBDD', skinShade: '#F2CDBD', blush: '#F29A9A', mouth: '#C9505A',
  iris: '#3A9AD9', irisDark: '#1D4C7E', irisLight: '#8FD3F2', pupil: '#14304F', lash: '#1A2236',
  outfit: '#F6F1E8',
  bangs: bangsA,
  back: `<path d="M268 474 C246 326 360 196 512 196 C664 196 778 326 756 474 C764 604 742 694 700 744 L600 704 H424 L324 744 C282 694 260 604 268 474 Z" fill="#1B2640"/>`,
  collar: `<path d="M512 836 L412 808 L440 912 Z" fill="#FFFFFF"/><path d="M512 836 L612 808 L584 912 Z" fill="#FFFFFF"/>
    <path d="M512 868 L452 840 L456 900 Z" fill="#B8333E"/><path d="M512 868 L572 840 L568 900 Z" fill="#B8333E"/><circle cx="512" cy="868" r="17" fill="#8E2430"/>`,
  front: `
    <path d="M296 408 C280 548 294 640 338 742 C350 700 360 650 366 606 C362 540 364 480 376 410 Z" fill="#243256"/>
    ${mirror('<path d="M296 408 C280 548 294 640 338 742 C350 700 360 650 366 606 C362 540 364 480 376 410 Z" fill="#243256"/>')}
    <path d="${bangsA}" fill="#243256"/>
    <path d="M386 322 Q424 292 468 286 Q430 302 396 334 Z" fill="#4A659C" opacity="1"/><path d="M492 280 Q532 276 570 284 Q532 290 494 294 Z" fill="#4A659C" opacity="1"/><path d="M594 290 Q632 300 656 322 Q626 312 592 304 Z" fill="#4A659C" opacity="1"/>
    <path d="M520 236 C516 168 560 136 606 148 C572 162 552 190 546 236 Z" fill="#243256"/>
    <path d="M282 470 C262 262 762 262 742 470" fill="none" stroke="#F6F1E8" stroke-width="24" stroke-linecap="round"/>
    <rect x="246" y="428" width="76" height="138" rx="36" fill="#F6F1E8"/><rect x="262" y="452" width="44" height="90" rx="22" fill="#B8333E"/>
    ${mirror('<rect x="246" y="428" width="76" height="138" rx="36" fill="#F6F1E8"/><rect x="262" y="452" width="44" height="90" rx="22" fill="#B8333E"/>')}`
};

/* ---------- B 小竹：薄荷长发、双小辫、金色星星 ---------- */
const bangsB = 'M290 474 C270 300 372 198 512 198 C652 198 754 300 734 472 Q708 446 698 416 Q684 468 656 500 Q648 446 622 424 Q604 470 574 494 Q568 442 542 420 Q528 468 496 504 Q488 448 460 426 Q442 470 414 490 Q406 446 390 428 Q372 462 342 482 Q314 478 290 474 Z';
const B = {
  id: 'b', title: 'Expert Chat · 小竹',
  bg: '#2F6F63', halo: '#3A8273', spark: '#F6E3A6',
  skin: '#FEEDE2', skinShade: '#F3D0C2', blush: '#F2A08F', mouth: '#C85A55',
  iris: '#E2A43C', irisDark: '#9C5A1E', irisLight: '#F7D78A', pupil: '#5A2E12', lash: '#24433D',
  outfit: '#26404F',
  bangs: bangsB,
  back: `
    <path d="M304 372 C214 372 156 460 164 590 C170 680 200 742 240 790 C222 712 226 650 252 600 C244 664 250 712 276 756 C278 650 292 566 330 506 Z" fill="#B5DCCF"/>
    ${mirror('<path d="M304 372 C214 372 156 460 164 590 C170 680 200 742 240 790 C222 712 226 650 252 600 C244 664 250 712 276 756 C278 650 292 566 330 506 Z" fill="#B5DCCF"/>')}
    <path d="M270 470 C250 322 364 196 512 196 C660 196 774 322 754 470 C762 600 760 700 728 770 Q690 744 650 740 H374 Q334 744 296 770 C264 700 262 600 270 470 Z" fill="#B5DCCF"/>`,
  collar: `<path d="M330 900 L512 980 L694 900 L720 1024 H304 Z" fill="#F6F1E8"/><path d="M380 872 L512 936 L644 872 L650 900 L512 966 L374 900 Z" fill="#26404F"/>
    <path d="M512 904 L458 878 L462 934 Z" fill="#E6B544"/><path d="M512 904 L566 878 L562 934 Z" fill="#E6B544"/><circle cx="512" cy="904" r="15" fill="#C8952C"/>`,
  front: `
    
    <path d="M296 408 C282 530 296 610 336 690 C348 660 358 630 364 596 C362 540 364 480 376 410 Z" fill="#D8EFE7"/>
    ${mirror('<path d="M296 408 C282 530 296 610 336 690 C348 660 358 630 364 596 C362 540 364 480 376 410 Z" fill="#D8EFE7"/>')}
    <path d="${bangsB}" fill="#D8EFE7"/>
    <path d="M386 322 Q424 292 468 286 Q430 302 396 334 Z" fill="#FFFFFF" opacity="0.85"/><path d="M492 280 Q532 276 570 284 Q532 290 494 294 Z" fill="#FFFFFF" opacity="0.85"/><path d="M594 290 Q632 300 656 322 Q626 312 592 304 Z" fill="#FFFFFF" opacity="0.85"/>
    <path d="M660 330 l16 34 37 5 -27 25 7 37 -33 -18 -33 18 7 -37 -27 -25 37 -5 Z" fill="#E6B544"/>
    <circle cx="278" cy="392" r="24" fill="#E6B544"/>${mirror('<circle cx="278" cy="392" r="24" fill="#E6B544"/>')}`
};

/* ---------- C 小绛：银紫长发、狐耳、胭脂发绳 ---------- */
const bangsC = 'M290 478 C268 302 372 202 512 202 C652 202 756 302 734 478 Q710 452 700 424 Q690 476 664 510 Q654 458 626 434 Q610 478 582 502 Q576 452 548 430 Q536 476 504 512 Q494 456 466 434 Q450 478 420 498 Q410 456 392 436 Q374 470 346 488 Q316 484 290 478 Z';
const C = {
  id: 'c', title: 'Expert Chat · 小绛',
  bg: '#7E2F45', halo: '#913A53', spark: '#F2D7DF',
  skin: '#FEEEE4', skinShade: '#F1CFC6', blush: '#EE8EA0', mouth: '#B94356',
  iris: '#8E6BD6', irisDark: '#46317D', irisLight: '#C9B6F2', pupil: '#2A1C4D', lash: '#3A2C4C',
  outfit: '#F4EFF2',
  bangs: bangsC,
  back: `
    <path d="M336 312 L292 120 L452 238 Z" fill="#DCD3EA"/><path d="M344 280 L318 168 L420 246 Z" fill="#F0B9C6"/>
    ${mirror('<path d="M336 312 L292 120 L452 238 Z" fill="#DCD3EA"/><path d="M344 280 L318 168 L420 246 Z" fill="#F0B9C6"/>')}
    <path d="M262 470 C240 316 360 200 512 200 C664 200 784 316 762 470 C770 640 800 820 850 1024 H174 C224 820 254 640 262 470 Z" fill="#C7BBDD"/>`,
  collar: `<path d="M512 836 L392 830 L470 1024 H520 Z" fill="#F4EFF2"/><path d="M512 836 L632 830 L560 1024 H470 Z" fill="#E7DFE6"/>
    <path d="M512 840 L560 840 L470 1024 H430 Z" fill="#B23A52"/>`,
  front: `
    <path d="M296 408 C280 548 294 710 338 812 C350 770 360 720 366 641 C362 540 364 480 376 410 Z" fill="#E9E3F2"/>
    ${mirror('<path d="M296 408 C280 548 294 710 338 812 C350 770 360 720 366 641 C362 540 364 480 376 410 Z" fill="#E9E3F2"/>')}
    <path d="${bangsC}" fill="#E9E3F2"/>
    <path d="M386 322 Q424 292 468 286 Q430 302 396 334 Z" fill="#FFFFFF" opacity="0.85"/><path d="M492 280 Q532 276 570 284 Q532 290 494 294 Z" fill="#FFFFFF" opacity="0.85"/><path d="M594 290 Q632 300 656 322 Q626 312 592 304 Z" fill="#FFFFFF" opacity="0.85"/>
    <path d="M340 742 L296 718 L300 770 Z" fill="#B23A52"/><path d="M340 742 L384 718 L380 770 Z" fill="#B23A52"/><circle cx="340" cy="744" r="13" fill="#8E2A3E"/><path d="M334 754 L322 830 L340 816 L356 830 L346 754 Z" fill="#B23A52"/>`
};

const all = [A, B, C];
fs.mkdirSync(path.join(OUT, 'preview'), { recursive: true });
for (const c of all) {
  const svg = icon(c);
  fs.writeFileSync(path.join(OUT, `mascot-${c.id}.svg`), svg);
  for (const size of [512, 48, 26]) {
    const png = new Resvg(svg, { fitTo: { mode: 'width', value: size } }).render().asPng();
    fs.writeFileSync(path.join(OUT, 'preview', `mascot-${c.id}-${size}.png`), png);
  }
}
// 一张总览：三个角色并排，含小尺寸
const sheet = `<svg xmlns="http://www.w3.org/2000/svg" width="1560" height="620" viewBox="0 0 1560 620"><rect width="1560" height="620" fill="#EEF1F4"/>
${all.map((c, i) => `<g transform="translate(${20 + i * 520} 20)"><g transform="scale(.46875)">${icon(c).replace(/^<svg[^>]*>/, '').replace(/<\/svg>$/, '')}</g>
<g transform="translate(0 500) scale(.046875)">${icon(c).replace(/^<svg[^>]*>/, '').replace(/<\/svg>$/, '')}</g>
<g transform="translate(70 500) scale(.0254)">${icon(c).replace(/^<svg[^>]*>/, '').replace(/<\/svg>$/, '')}</g></g>`).join('')}
</svg>`;
fs.writeFileSync(path.join(OUT, 'preview', 'sheet.png'), new Resvg(sheet).render().asPng());
console.log('done');
