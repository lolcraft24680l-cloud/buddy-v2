# BUDDY 2.0

## Neu hochladen

Diese Dateien in den Hauptordner des Repos (alte ueberschreiben):

  BUDDYApp.swift, ContentView.swift, Dateien.swift, Gehirn.swift,
  Gesicht.swift, KI.swift, Stimme.swift, Werkzeuge.swift,
  make_icon.py, project.yml

Dateien.swift ist NEU. Gemini.swift muss weg, falls noch da.

## Die Oberflaeche ist jetzt leer

Nur das Gesicht. Kein Textfeld, kein Knopf, keine Leiste. Alles laeuft
ueber Gesten, und jedes Fenster verschwindet, sobald es gebraucht wurde:

- irgendwo tippen        -> zuhoeren
- nach oben wischen      -> Schreibfenster (schliesst nach dem Senden)
- nach unten wischen     -> Gedaechtnis
- seitwaerts wischen     -> Einstellungen
- neben ein Fenster tippen oder nach unten ziehen -> schliessen

## Weckwort

In den Einstellungen "Auf Buddy hoeren" anschalten. Dann lauscht er
dauerhaft und geraetelokal — es geht nichts ins Netz, solange das Wort
nicht faellt. Sagst du "Buddy, wie wird das Wetter", nimmt er den Rest
des Satzes gleich als Befehl. Sagst du nur "Buddy", schaltet er das
Mikrofon an und wartet.

Der kleine Punkt unten leuchtet, solange er lauscht. Kostet Akku —
wenn du sparen willst, ausschalten und antippen.

## Stimme

Unter Einstellungen kannst du jede deutsche Stimme des Geraets waehlen,
dazu Tonhoehe und Tempo regeln, und dir das Ergebnis anhoeren.
Voreingestellt ist hell und jung.

WICHTIG fuer echten Klang: iOS liefert ab Werk nur die Blechstimme mit.
Einstellungen -> Bedienungshilfen -> Gesprochene Inhalte -> Stimmen ->
Deutsch -> eine Premium-Stimme laden. Danach taucht sie in BUDDY auf.
Ohne diesen Schritt klingt keine App auf dem iPhone natuerlich.

## Dateien und Bilder

Sag "analysiere die Datei" oder "schau dir das an" — das Fenster geht
von selbst auf und danach wieder zu. Er liest PDFs (auch gescannte,
per Texterkennung), Bilder, Text-, Code- und Datendateien.
Alles Auslesen passiert auf dem Geraet.

## Gedaechtnis

Nach jeder Antwort laeuft im Hintergrund ein zweiter Durchgang, der
Fakten ueber dich herauszieht und einsortiert — in 17 Bereiche von
Person und Arbeit ueber Essen, Musik und Sport bis zu festen Terminen.
Du musst ihm nichts mehr ausdruecklich sagen. Im Gedaechtnisfenster
siehst du alles, kannst selbst etwas hinzufuegen und Einzelnes loeschen.

## Persoenlichkeit

Vier Rollen unter Einstellungen: Kumpel, Sachlich, Erklaerer, Frech.

## Neue Werkzeuge

Rechner, Dateiauswahl oeffnen, Kamera oeffnen — dazu alles aus 1.2:
Wetter, Nachrichten, Kurse, Websuche, Wikipedia, Standort, Navigation,
Taschenlampe, Helligkeit, Musik, Akku, Zwischenablage, Apps, Anrufe,
Nachrichten, Kurzbefehle, Erinnerungen, Termine, Gedaechtnis.

## Animationen

Wellenform beim Zuhoeren, treibende Lichtpunkte im Hintergrund,
Milchglasfenster mit Neonrand, und das Gesicht wie gehabt mit neun
Zustaenden.

## Was noch nicht drin ist

Multi-Agent-System mit Dashboard, Live-Uebersetzung, Emotionserkennung,
Confidence-Meter, Thought-Graph. Kommt als Stufe zwei.

## Was auf dem iPhone nicht geht

Telefon-Agent: iOS laesst keine App Ton in ein Telefonat geben.
Browser-Agent mit Klicks: keine Automatisierung erlaubt.
Sprecher-Erkennung: es gibt keine API dafuer.
