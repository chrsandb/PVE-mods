#!/usr/bin/env node
// Execute the actual renderer/helpers with a small Ext API stub, not a copied UI.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const definitions = {};
let lastWindow;
const encode = value => String(value).replaceAll('&', '&amp;').replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&#39;');
const Ext = {
    define: (name, definition) => { definitions[name] = definition; },
    util: {Format: {htmlEncode: encode, number: value => Number(value).toFixed(1)}},
    getBody: () => ({getViewSize: () => ({width: 1100, height: 720})}),
    create: (name, config) => {
        assert.equal(name, 'Ext.window.Window');
        lastWindow = {...config, show() {}, toFront() { this.raised = true; }, close() {
            this.destroyed = true;
            this.listeners.destroy();
        }};
        return lastWindow;
    },
};
const context = vm.createContext({Ext, Proxmox: {Utils: {}}, PVE: {Utils: {}}, gettext: text => text, console});
vm.runInContext(fs.readFileSync(path.join(__dirname, '../../src/modules/node_info/files/PveMods_pvemanagerlib.js'), 'utf8'), context);
const groups = info => context.getCpuThermalGroups(info);
const thermal = definitions['PVE.node.StatusView'].items.find(item => item.itemId === 'thermalCpu');
const intel = (count, packageId = 0) => {
    const chip = {cpu_model: '64-core server CPU', cpu_package: packageId,
        temp1: {label: `Package id ${packageId}`, input: 60, max: 80, crit: 100}};
    for (let core = 0; core < count; core++) {
        chip[`temp${core + 2}`] = {label: `Core ${core}`, input: 40 + core % 10, max: 80, crit: 100};
    }
    return chip;
};
const info = (payload, extra = {}) => ({cpu: true, cpu_temp_target: 'Core', temp_unit: 'C',
    ignore_temp_below: 5, enhanced_sensors: payload, ...extra});
const render = input => {
    const widget = {hide() { this.hidden = true; }};
    return {widget, html: thermal.renderer.call(widget, input)};
};
let tests = 0;
function test(name, body) {
    body(); tests++;
    console.log(`PASS: ${name}`);
}

test('64 physical-core sensors do not become 128 thread sensors or inline readings', () => {
    const {widget, html} = render(info({'coretemp-isa-0000': intel(64)}, {threads: 128}));
    assert.equal(widget.cpuThermalGroups[0].rows.length, 65);
    assert.equal(widget.cpuThermalGroups[0].selected.length, 64);
    assert.match(html, /64 core sensors/);
    assert.match(html, /Min 40.0°C · Avg 44.3°C · Max 49.0°C/);
    assert.doesNotMatch(html, /Core 63/);
    assert.ok(html.length < 1100, html.length);
});

test('two sockets keep repeated core indices separate in bounded summaries', () => {
    const input = info({'coretemp-isa-0001': intel(64, 1), 'coretemp-isa-0000': intel(64, 0)});
    const {widget, html} = render(input);
    assert.equal(widget.cpuThermalGroups.length, 2);
    assert.equal(widget.cpuThermalGroups.reduce((sum, group) => sum + group.selected.length, 0), 128);
    assert.match(html, /Package 0/);
    assert.match(html, /Package 1/);
    assert.ok(html.length < 1800, html.length);
});

test('package selection is honored, with a core fallback when package is unavailable', () => {
    const chip = intel(64);
    assert.equal(groups(info({'coretemp-isa-0': chip}, {cpu_temp_target: 'Package'}))[0].selected[0].kind, 'package');
    delete chip.temp1;
    const group = groups(info({'coretemp-isa-0': chip}, {cpu_temp_target: 'Package'}))[0];
    assert.equal(group.selected.length, 64);
    assert.equal(group.scope, 'Core sensors');
});

test('AMD CCD and package choices are per chip; Tdie and offset Tctl are not averaged', () => {
    const amd = {cpu_package: 0, cpu_model: 'EPYC', temp1: {label: 'Tctl', input: 80},
        temp2: {label: 'Tdie', input: 60}};
    for (let ccd = 1; ccd <= 8; ccd++) amd[`temp${ccd + 2}`] = {label: `Tccd${ccd}`, input: 40 + ccd};
    const payload = {'k10temp-pci-0000': amd, 'k10temp-pci-0001': {cpu_package: 1, temp1: {label: 'Tctl', input: 55}}};
    const coreGroups = groups(info(payload));
    assert.equal(coreGroups[0].selected.length, 8);
    assert.equal(coreGroups[1].selected[0].label, 'Tctl');
    const packageGroups = groups(info(payload, {cpu_temp_target: 'Package'}));
    assert.equal(packageGroups[0].selected.length, 1);
    assert.equal(packageGroups[0].selected[0].value, 60);
    assert.equal(packageGroups[0].rows.length, 10);
});

test('P/E core labels, legacy input shape, and numeric ordering are preserved', () => {
    const group = groups(info({'coretemp-isa-0': {
        'Core 10': {temp10_input: 50}, 'Core 2': {temp2_input: 40},
        temp3: {label: 'P Core 1', input: 41}, temp4: {label: 'E Core 3', input: 42},
    }}))[0];
    assert.equal(group.selected.length, 4);
    assert.ok(group.rows.findIndex(row => row.label === 'Core 2') < group.rows.findIndex(row => row.label === 'Core 10'));
});

test('Raspberry Pi and AMD overall-temperature fallback retain their labels', () => {
    const pi = groups(info({'cpu_thermal-virtual-0': {temp1: {input: 45.5}}}))[0];
    assert.equal(pi.selected[0].value, 45.5);
    assert.equal(pi.selected[0].label, 'temp1');
    const amd = groups(info({'k10temp-pci-0': {'CPU Core Temp': {temp1_input: 62}}}, {cpu_temp_target: 'Package'}))[0];
    assert.equal(amd.selected[0].label, 'CPU Core Temp');
    assert.equal(amd.selected[0].value, 62);
});

test('Fahrenheit converts values and summaries while threshold decisions stay correct', () => {
    const {html} = render(info({'coretemp-isa-0': {temp1: {label: 'Core 0', input: 90, crit: 85}}}, {temp_unit: 'F'}));
    assert.match(html, /194.0°F/);
    assert.match(html, /Critical/);
});

test('missing readings are not synthesized as zero and missing data remains N/A', () => {
    for (const input of [null, '', false, undefined, 'N/A']) {
        assert.ok(Number.isNaN(context.getSensorValue({input}, 'input')));
    }
    assert.equal(render(info({})).html, 'N/A');
    assert.equal(render(info({'coretemp-isa-0': {temp1: {label: 'Core 0', input: null}}})).html, 'N/A');
    const chip = intel(1);
    chip.temp2.input = 0;
    delete chip.temp1;
    assert.equal(groups(info({'coretemp-isa-0': chip}, {ignore_temp_below: 0}))[0].selected[0].value, 0);
});

test('summary HTML escapes model and source identifiers', () => {
    const chip = intel(1);
    chip.cpu_model = '<img src=x onerror=alert(1)>';
    const {html} = render(info({'coretemp-isa-0': chip}));
    assert.doesNotMatch(html, /<img/);
    assert.match(html, /&lt;img/);
});

test('disabled CPU monitoring clears details and hides its widget', () => {
    const {widget, html} = render(info({'coretemp-isa-0': intel(64)}, {cpu: false}));
    assert.equal(html, '');
    assert.equal(widget.hidden, true);
    assert.equal(widget.cpuThermalGroups.length, 0);
});

test('details window includes every sensor, scrolls and survives summary refresh', () => {
    const input = info({'coretemp-isa-0': intel(64), 'coretemp-isa-1': intel(64, 1)});
    const {widget} = render(input);
    context.showCpuThermalDetails(widget);
    const window = lastWindow;
    assert.equal(window.items[0].store.data.length, 130);
    assert.equal(window.items[0].scrollable, true);
    assert.ok(window.height <= 560);
    assert.match(window.title, /snapshot/);
    thermal.renderer.call(widget, input);
    assert.equal(widget.cpuThermalWindow, window);
    context.showCpuThermalDetails(widget);
    assert.equal(lastWindow, window);
    assert.equal(window.raised, true);
    thermal.listeners.beforedestroy(widget);
    assert.equal(window.destroyed, true);
    assert.equal(widget.cpuThermalWindow, null);
});

console.log(`${tests} CPU layout tests passed`);
