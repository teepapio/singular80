import { describe, expect, it } from 'vitest';
import { MAX_TASKS, normalizeTasks, splitIntoTasks } from '../server/split';

describe('splitIntoTasks', () => {
  it('teilt Zeilenlisten in Einzelaufträge', () => {
    const tasks = splitIntoTasks('Neue Waffe hinzufügen\nNeuen Gegner einbauen');
    expect(tasks).toEqual(['Neue Waffe hinzufügen', 'Neuen Gegner einbauen']);
  });

  it('entfernt Listenmarkierungen', () => {
    const tasks = splitIntoTasks('- Ersten Boss hinzufügen\n- Zweiten Boss hinzufügen');
    expect(tasks).toEqual(['Ersten Boss hinzufügen', 'Zweiten Boss hinzufügen']);
  });

  it('teilt an Satzgrenzen', () => {
    const tasks = splitIntoTasks('Der Boss ist zu stark. Bitte seine Lebenspunkte senken.');
    expect(tasks).toHaveLength(2);
    expect(tasks[0]).toContain('Boss');
    expect(tasks[1]).toContain('Lebenspunkte');
  });

  it('teilt an Konjunktionen', () => {
    const tasks = splitIntoTasks('Füge einen neuen Gegner hinzu und ändere die Farbe des HUD');
    expect(tasks).toHaveLength(2);
    expect(tasks[0]).toContain('Gegner');
    expect(tasks[1]).toContain('HUD');
  });

  it('gibt den Originaltext zurück, wenn kein sinnvoller Split möglich ist', () => {
    const text = 'Bitte die Lautstärke leiser machen';
    expect(splitIntoTasks(text)).toEqual([text]);
  });

  it('behandelt leere Eingaben', () => {
    expect(splitIntoTasks('   ')).toEqual([]);
  });

  it('begrenzt die Anzahl der Teile', () => {
    const text = Array.from({ length: MAX_TASKS + 5 }, (_, i) => `Auftrag Nummer ${i}`).join('\n');
    expect(splitIntoTasks(text).length).toBe(MAX_TASKS);
  });
});

describe('normalizeTasks', () => {
  it('trimmt und akzeptiert gültige Aufträge', () => {
    expect(normalizeTasks(['  Erster Auftrag  ', 'Zweiter Auftrag'])).toEqual({
      tasks: ['Erster Auftrag', 'Zweiter Auftrag'],
    });
  });

  it('lehnt Nicht-Listen ab', () => {
    expect(normalizeTasks('nope').error).toBeTruthy();
  });

  it('lehnt zu kurze Aufträge ab', () => {
    expect(normalizeTasks(['ok', 'x']).error).toBeTruthy();
  });

  it('lehnt leere Listen ab', () => {
    expect(normalizeTasks([]).error).toBeTruthy();
  });

  it('verlangt mindestens zwei Aufträge', () => {
    expect(normalizeTasks(['Nur ein Auftrag']).error).toBeTruthy();
  });

  it('lehnt zu viele Aufträge ab', () => {
    const many = Array.from({ length: MAX_TASKS + 1 }, (_, i) => `Auftrag Nummer ${i}`);
    expect(normalizeTasks(many).error).toBeTruthy();
  });
});
