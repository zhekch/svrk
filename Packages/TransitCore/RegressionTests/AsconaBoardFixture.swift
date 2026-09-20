import Foundation

/// Captured reference/stop shapes for FART course 1054, with a fixed +4 estimate.
enum AsconaBoardFixture {
    static let mirror = Data(#"""
{
  "station": {
    "id": "8591522",
    "name": "Ascona, Scuole",
    "score": null,
    "coordinate": {
      "type": "WGS84",
      "x": 46.154307,
      "y": 8.774018
    },
    "distance": null
  },
  "stationboard": [
    {
      "stop": {
        "station": {
          "id": "8591522",
          "name": "Ascona, Scuole",
          "score": null,
          "coordinate": {
            "type": "WGS84",
            "x": 46.154307,
            "y": 8.774018
          },
          "distance": null
        },
        "arrival": null,
        "arrivalTimestamp": null,
        "departure": "2026-09-07T10:09:00+0200",
        "departureTimestamp": 1788768540,
        "delay": null,
        "platform": null,
        "prognosis": {
          "platform": null,
          "arrival": "2026-09-07T10:11:45+0200",
          "departure": null,
          "capacity1st": null,
          "capacity2nd": null
        },
        "realtimeAvailability": null,
        "location": {
          "id": "8508245",
          "name": null,
          "score": null,
          "coordinate": {
            "type": "WGS84",
            "x": null,
            "y": null
          },
          "distance": null
        }
      },
      "name": "001054",
      "category": "B",
      "subcategory": null,
      "categoryCode": null,
      "number": "1",
      "operator": "FART Aut",
      "to": "Losone, Sottochiesa",
      "passList": [
        {
          "station": {
            "id": "8508245",
            "name": null,
            "score": null,
            "coordinate": {
              "type": "WGS84",
              "x": null,
              "y": null
            },
            "distance": null
          },
          "arrival": null,
          "arrivalTimestamp": null,
          "departure": "2026-09-07T10:09:00+0200",
          "departureTimestamp": 1788768540,
          "delay": null,
          "platform": null,
          "prognosis": {
            "platform": null,
            "arrival": "2026-09-07T10:11:45+0200",
            "departure": null,
            "capacity1st": null,
            "capacity2nd": null
          },
          "realtimeAvailability": null,
          "location": {
            "id": "8508245",
            "name": null,
            "score": null,
            "coordinate": {
              "type": "WGS84",
              "x": null,
              "y": null
            },
            "distance": null
          }
        },
        {
          "station": {
            "id": "8505850",
            "name": "Ascona, Centro",
            "score": null,
            "coordinate": {
              "type": "WGS84",
              "x": 46.15552,
              "y": 8.771057
            },
            "distance": null
          },
          "arrival": "2026-09-07T10:11:00+0200",
          "arrivalTimestamp": 1788768660,
          "departure": "2026-09-07T10:11:00+0200",
          "departureTimestamp": 1788768660,
          "delay": null,
          "platform": null,
          "prognosis": {
            "platform": null,
            "arrival": null,
            "departure": null,
            "capacity1st": null,
            "capacity2nd": null
          },
          "realtimeAvailability": null,
          "location": {
            "id": "8505850",
            "name": "Ascona, Centro",
            "score": null,
            "coordinate": {
              "type": "WGS84",
              "x": 46.15552,
              "y": 8.771057
            },
            "distance": null
          }
        },
        {
          "station": {
            "id": "8591527",
            "name": "Ascona, Parco dei Poeti",
            "score": null,
            "coordinate": {
              "type": "WGS84",
              "x": 46.156931,
              "y": 8.773513
            },
            "distance": null
          },
          "arrival": "2026-09-07T10:11:00+0200",
          "arrivalTimestamp": 1788768660,
          "departure": "2026-09-07T10:11:00+0200",
          "departureTimestamp": 1788768660,
          "delay": null,
          "platform": null,
          "prognosis": {
            "platform": null,
            "arrival": null,
            "departure": null,
            "capacity1st": null,
            "capacity2nd": null
          },
          "realtimeAvailability": null,
          "location": {
            "id": "8591527",
            "name": "Ascona, Parco dei Poeti",
            "score": null,
            "coordinate": {
              "type": "WGS84",
              "x": 46.156931,
              "y": 8.773513
            },
            "distance": null
          }
        },
        {
          "station": {
            "id": "8591528",
            "name": "Ascona, Via Medere",
            "score": null,
            "coordinate": {
              "type": "WGS84",
              "x": 46.160138,
              "y": 8.775391
            },
            "distance": null
          },
          "arrival": "2026-09-07T10:12:00+0200",
          "arrivalTimestamp": 1788768720,
          "departure": "2026-09-07T10:12:00+0200",
          "departureTimestamp": 1788768720,
          "delay": null,
          "platform": null,
          "prognosis": {
            "platform": null,
            "arrival": null,
            "departure": null,
            "capacity1st": null,
            "capacity2nd": null
          },
          "realtimeAvailability": null,
          "location": {
            "id": "8591528",
            "name": "Ascona, Via Medere",
            "score": null,
            "coordinate": {
              "type": "WGS84",
              "x": 46.160138,
              "y": 8.775391
            },
            "distance": null
          }
        },
        {
          "station": {
            "id": "8591518",
            "name": "Ascona, Manor Delta",
            "score": null,
            "coordinate": {
              "type": "WGS84",
              "x": 46.162858,
              "y": 8.774409
            },
            "distance": null
          },
          "arrival": "2026-09-07T10:14:00+0200",
          "arrivalTimestamp": 1788768840,
          "departure": "2026-09-07T10:14:00+0200",
          "departureTimestamp": 1788768840,
          "delay": null,
          "platform": null,
          "prognosis": {
            "platform": null,
            "arrival": null,
            "departure": null,
            "capacity1st": null,
            "capacity2nd": null
          },
          "realtimeAvailability": null,
          "location": {
            "id": "8591518",
            "name": "Ascona, Manor Delta",
            "score": null,
            "coordinate": {
              "type": "WGS84",
              "x": 46.162858,
              "y": 8.774409
            },
            "distance": null
          }
        },
        {
          "station": {
            "id": "8578924",
            "name": "Losone, Ponte Maggia",
            "score": null,
            "coordinate": {
              "type": "WGS84",
              "x": 46.165596,
              "y": 8.772611
            },
            "distance": null
          },
          "arrival": "2026-09-07T10:15:00+0200",
          "arrivalTimestamp": 1788768900,
          "departure": "2026-09-07T10:15:00+0200",
          "departureTimestamp": 1788768900,
          "delay": null,
          "platform": null,
          "prognosis": {
            "platform": null,
            "arrival": null,
            "departure": null,
            "capacity1st": null,
            "capacity2nd": null
          },
          "realtimeAvailability": null,
          "location": {
            "id": "8578924",
            "name": "Losone, Ponte Maggia",
            "score": null,
            "coordinate": {
              "type": "WGS84",
              "x": 46.165596,
              "y": 8.772611
            },
            "distance": null
          }
        },
        {
          "station": {
            "id": "8576451",
            "name": "Losone, Mercato Cattori",
            "score": null,
            "coordinate": {
              "type": "WGS84",
              "x": 46.165352,
              "y": 8.768889
            },
            "distance": null
          },
          "arrival": "2026-09-07T10:16:00+0200",
          "arrivalTimestamp": 1788768960,
          "departure": "2026-09-07T10:16:00+0200",
          "departureTimestamp": 1788768960,
          "delay": null,
          "platform": null,
          "prognosis": {
            "platform": null,
            "arrival": null,
            "departure": null,
            "capacity1st": null,
            "capacity2nd": null
          },
          "realtimeAvailability": null,
          "location": {
            "id": "8576451",
            "name": "Losone, Mercato Cattori",
            "score": null,
            "coordinate": {
              "type": "WGS84",
              "x": 46.165352,
              "y": 8.768889
            },
            "distance": null
          }
        },
        {
          "station": {
            "id": "8591549",
            "name": "Losone, Agricola",
            "score": null,
            "coordinate": {
              "type": "WGS84",
              "x": 46.165176,
              "y": 8.766308
            },
            "distance": null
          },
          "arrival": "2026-09-07T10:17:00+0200",
          "arrivalTimestamp": 1788769020,
          "departure": "2026-09-07T10:17:00+0200",
          "departureTimestamp": 1788769020,
          "delay": null,
          "platform": null,
          "prognosis": {
            "platform": null,
            "arrival": null,
            "departure": null,
            "capacity1st": null,
            "capacity2nd": null
          },
          "realtimeAvailability": null,
          "location": {
            "id": "8591549",
            "name": "Losone, Agricola",
            "score": null,
            "coordinate": {
              "type": "WGS84",
              "x": 46.165176,
              "y": 8.766308
            },
            "distance": null
          }
        },
        {
          "station": {
            "id": "8591554",
            "name": "Losone, Via Cesura",
            "score": null,
            "coordinate": {
              "type": "WGS84",
              "x": 46.167851,
              "y": 8.762217
            },
            "distance": null
          },
          "arrival": "2026-09-07T10:18:00+0200",
          "arrivalTimestamp": 1788769080,
          "departure": "2026-09-07T10:18:00+0200",
          "departureTimestamp": 1788769080,
          "delay": null,
          "platform": null,
          "prognosis": {
            "platform": null,
            "arrival": null,
            "departure": null,
            "capacity1st": null,
            "capacity2nd": null
          },
          "realtimeAvailability": null,
          "location": {
            "id": "8591554",
            "name": "Losone, Via Cesura",
            "score": null,
            "coordinate": {
              "type": "WGS84",
              "x": 46.167851,
              "y": 8.762217
            },
            "distance": null
          }
        },
        {
          "station": {
            "id": "8508245",
            "name": "Losone, Sottochiesa",
            "score": null,
            "coordinate": {
              "type": "WGS84",
              "x": 46.169366,
              "y": 8.760389
            },
            "distance": null
          },
          "arrival": "2026-09-07T10:21:00+0200",
          "arrivalTimestamp": 1788769260,
          "departure": null,
          "departureTimestamp": null,
          "delay": null,
          "platform": null,
          "prognosis": {
            "platform": null,
            "arrival": null,
            "departure": null,
            "capacity1st": null,
            "capacity2nd": null
          },
          "realtimeAvailability": null,
          "location": {
            "id": "8508245",
            "name": "Losone, Sottochiesa",
            "score": null,
            "coordinate": {
              "type": "WGS84",
              "x": 46.169366,
              "y": 8.760389
            },
            "distance": null
          }
        }
      ],
      "capacity1st": null,
      "capacity2nd": null
    }
  ]
}
"""#.utf8)
    static let ojp = Data(#"""
<StopEventResult><Id>717aefcb-0939-4da9-ae7f-c8732b20f156</Id><StopEvent><PreviousCall><CallAtStop><siri:StopPointRef>ch:1:sloid:6520::311701</siri:StopPointRef><StopPointName><Text xml:lang="de">Gordola, Centro Professionale</Text></StopPointName><ServiceDeparture><TimetabledTime>2026-09-07T07:40:00Z</TimetabledTime><EstimatedTime>2026-09-07T07:44:00Z</EstimatedTime></ServiceDeparture><Order>1</Order></CallAtStop></PreviousCall><PreviousCall><CallAtStop><siri:StopPointRef>ch:1:sloid:6519:0:1</siri:StopPointRef><StopPointName><Text xml:lang="de">Gordola, Roviscaglie</Text></StopPointName><ServiceArrival><TimetabledTime>2026-09-07T07:40:00Z</TimetabledTime><EstimatedTime>2026-09-07T07:44:00Z</EstimatedTime></ServiceArrival><ServiceDeparture><TimetabledTime>2026-09-07T07:40:00Z</TimetabledTime><EstimatedTime>2026-09-07T07:44:00Z</EstimatedTime></ServiceDeparture><Order>2</Order></CallAtStop></PreviousCall><PreviousCall><CallAtStop><siri:StopPointRef>ch:1:sloid:81771::338002</siri:StopPointRef><StopPointName><Text xml:lang="de">Tenero, Brere</Text></StopPointName><PlannedQuay><Text xml:lang="de">D</Text></PlannedQuay><ServiceArrival><TimetabledTime>2026-09-07T07:42:00Z</TimetabledTime><EstimatedTime>2026-09-07T07:46:00Z</EstimatedTime></ServiceArrival><ServiceDeparture><TimetabledTime>2026-09-07T07:42:00Z</TimetabledTime><EstimatedTime>2026-09-07T07:46:00Z</EstimatedTime></ServiceDeparture><Order>3</Order></CallAtStop></PreviousCall><PreviousCall><CallAtStop><siri:StopPointRef>ch:1:sloid:81778::310002</siri:StopPointRef><StopPointName><Text xml:lang="de">Tenero, Centro Commerciale</Text></StopPointName><ServiceArrival><TimetabledTime>2026-09-07T07:44:00Z</TimetabledTime><EstimatedTime>2026-09-07T07:48:00Z</EstimatedTime></ServiceArrival><ServiceDeparture><TimetabledTime>2026-09-07T07:44:00Z</TimetabledTime><EstimatedTime>2026-09-07T07:48:00Z</EstimatedTime></ServiceDeparture><Order>4</Order></CallAtStop></PreviousCall><PreviousCall><CallAtStop><siri:StopPointRef>ch:1:sloid:75177::311002</siri:StopPointRef><StopPointName><Text xml:lang="de">Tenero, Stazione</Text></StopPointName><ServiceArrival><TimetabledTime>2026-09-07T07:46:00Z</TimetabledTime><EstimatedTime>2026-09-07T07:50:00Z</EstimatedTime></ServiceArrival><ServiceDeparture><TimetabledTime>2026-09-07T07:46:00Z</TimetabledTime><EstimatedTime>2026-09-07T07:50:00Z</EstimatedTime></ServiceDeparture><Order>5</Order></CallAtStop></PreviousCall><PreviousCall><CallAtStop><siri:StopPointRef>ch:1:sloid:80984::346602</siri:StopPointRef><StopPointName><Text xml:lang="de">Tenero, Stella d'Oro</Text></StopPointName><ServiceArrival><TimetabledTime>2026-09-07T07:47:00Z</TimetabledTime><EstimatedTime>2026-09-07T07:51:00Z</EstimatedTime></ServiceArrival><ServiceDeparture><TimetabledTime>2026-09-07T07:47:00Z</TimetabledTime><EstimatedTime>2026-09-07T07:51:00Z</EstimatedTime></ServiceDeparture><Order>6</Order></CallAtStop></PreviousCall><PreviousCall><CallAtStop><siri:StopPointRef>ch:1:sloid:78942::310102</siri:StopPointRef><StopPointName><Text xml:lang="de">Minusio, Mappo</Text></StopPointName><ServiceArrival><TimetabledTime>2026-09-07T07:47:00Z</TimetabledTime><EstimatedTime>2026-09-07T07:51:00Z</EstimatedTime></ServiceArrival><ServiceDeparture><TimetabledTime>2026-09-07T07:47:00Z</TimetabledTime><EstimatedTime>2026-09-07T07:51:00Z</EstimatedTime></ServiceDeparture><Order>7</Order></CallAtStop></PreviousCall><PreviousCall><CallAtStop><siri:StopPointRef>ch:1:sloid:88815::309802</siri:StopPointRef><StopPointName><Text xml:lang="de">Minusio, Ignifera</Text></StopPointName><PlannedQuay><Text xml:lang="de">2</Text></PlannedQuay><ServiceArrival><TimetabledTime>2026-09-07T07:48:00Z</TimetabledTime><EstimatedTime>2026-09-07T07:52:00Z</EstimatedTime></ServiceArrival><ServiceDeparture><TimetabledTime>2026-09-07T07:48:00Z</TimetabledTime><EstimatedTime>2026-09-07T07:52:00Z</EstimatedTime></ServiceDeparture><Order>8</Order></CallAtStop></PreviousCall><PreviousCall><CallAtStop><siri:StopPointRef>ch:1:sloid:91558::302502</siri:StopPointRef><StopPointName><Text xml:lang="de">Minusio, Ponte Navegna</Text></StopPointName><ServiceArrival><TimetabledTime>2026-09-07T07:49:00Z</TimetabledTime><EstimatedTime>2026-09-07T07:53:00Z</EstimatedTime></ServiceArrival><ServiceDeparture><TimetabledTime>2026-09-07T07:49:00Z</TimetabledTime><EstimatedTime>2026-09-07T07:53:00Z</EstimatedTime></ServiceDeparture><Order>9</Order></CallAtStop></PreviousCall><PreviousCall><CallAtStop><siri:StopPointRef>ch:1:sloid:5604::302402</siri:StopPointRef><StopPointName><Text xml:lang="de">Minusio, Esplanade</Text></StopPointName><ServiceArrival><TimetabledTime>2026-09-07T07:49:00Z</TimetabledTime><EstimatedTime>2026-09-07T07:53:00Z</EstimatedTime></ServiceArrival><ServiceDeparture><TimetabledTime>2026-09-07T07:49:00Z</TimetabledTime><EstimatedTime>2026-09-07T07:53:00Z</EstimatedTime></ServiceDeparture><Order>10</Order></CallAtStop></PreviousCall><PreviousCall><CallAtStop><siri:StopPointRef>ch:1:sloid:91559::302302</siri:StopPointRef><StopPointName><Text xml:lang="de">Minusio, Remorino</Text></StopPointName><ServiceArrival><TimetabledTime>2026-09-07T07:50:00Z</TimetabledTime><EstimatedTime>2026-09-07T07:54:00Z</EstimatedTime></ServiceArrival><ServiceDeparture><TimetabledTime>2026-09-07T07:50:00Z</TimetabledTime><EstimatedTime>2026-09-07T07:54:00Z</EstimatedTime></ServiceDeparture><Order>11</Order></CallAtStop></PreviousCall><PreviousCall><CallAtStop><siri:StopPointRef>ch:1:sloid:91555::302202</siri:StopPointRef><StopPointName><Text xml:lang="de">Minusio, Crocifisso</Text></StopPointName><ServiceArrival><TimetabledTime>2026-09-07T07:51:00Z</TimetabledTime><EstimatedTime>2026-09-07T07:55:00Z</EstimatedTime></ServiceArrival><ServiceDeparture><TimetabledTime>2026-09-07T07:51:00Z</TimetabledTime><EstimatedTime>2026-09-07T07:55:00Z</EstimatedTime></ServiceDeparture><Order>12</Order></CallAtStop></PreviousCall><PreviousCall><CallAtStop><siri:StopPointRef>ch:1:sloid:5610::302102</siri:StopPointRef><StopPointName><Text xml:lang="de">Minusio, Piazza</Text></StopPointName><ServiceArrival><TimetabledTime>2026-09-07T07:53:00Z</TimetabledTime><EstimatedTime>2026-09-07T07:57:00Z</EstimatedTime></ServiceArrival><ServiceDeparture><TimetabledTime>2026-09-07T07:53:00Z</TimetabledTime><EstimatedTime>2026-09-07T07:57:00Z</EstimatedTime></ServiceDeparture><Order>13</Order></CallAtStop></PreviousCall><PreviousCall><CallAtStop><siri:StopPointRef>ch:1:sloid:91563::301902</siri:StopPointRef><StopPointName><Text xml:lang="de">Muralto, Via Sociale</Text></StopPointName><ServiceArrival><TimetabledTime>2026-09-07T07:54:00Z</TimetabledTime><EstimatedTime>2026-09-07T07:58:00Z</EstimatedTime></ServiceArrival><ServiceDeparture><TimetabledTime>2026-09-07T07:54:00Z</TimetabledTime><EstimatedTime>2026-09-07T07:58:00Z</EstimatedTime></ServiceDeparture><Order>14</Order></CallAtStop></PreviousCall><PreviousCall><CallAtStop><siri:StopPointRef>ch:1:sloid:87845::309502</siri:StopPointRef><StopPointName><Text xml:lang="de">Muralto, Al Parco</Text></StopPointName><ServiceArrival><TimetabledTime>2026-09-07T07:55:00Z</TimetabledTime><EstimatedTime>2026-09-07T07:59:00Z</EstimatedTime></ServiceArrival><ServiceDeparture><TimetabledTime>2026-09-07T07:55:00Z</TimetabledTime><EstimatedTime>2026-09-07T07:59:00Z</EstimatedTime></ServiceDeparture><Order>15</Order></CallAtStop></PreviousCall><PreviousCall><CallAtStop><siri:StopPointRef>ch:1:sloid:94370::300102</siri:StopPointRef><StopPointName><Text xml:lang="de">Locarno, Piazza Stazione</Text></StopPointName><PlannedQuay><Text xml:lang="de">C</Text></PlannedQuay><ServiceArrival><TimetabledTime>2026-09-07T07:59:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:03:00Z</EstimatedTime></ServiceArrival><ServiceDeparture><TimetabledTime>2026-09-07T07:59:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:03:00Z</EstimatedTime></ServiceDeparture><Order>16</Order></CallAtStop></PreviousCall><PreviousCall><CallAtStop><siri:StopPointRef>ch:1:sloid:80990::300202</siri:StopPointRef><StopPointName><Text xml:lang="de">Locarno, Debarcadero</Text></StopPointName><ServiceArrival><TimetabledTime>2026-09-07T07:59:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:03:00Z</EstimatedTime></ServiceArrival><ServiceDeparture><TimetabledTime>2026-09-07T07:59:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:03:00Z</EstimatedTime></ServiceDeparture><Order>17</Order></CallAtStop></PreviousCall><PreviousCall><CallAtStop><siri:StopPointRef>ch:1:sloid:80991::303202</siri:StopPointRef><StopPointName><Text xml:lang="de">Locarno, Centro</Text></StopPointName><ServiceArrival><TimetabledTime>2026-09-07T08:02:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:06:00Z</EstimatedTime></ServiceArrival><ServiceDeparture><TimetabledTime>2026-09-07T08:02:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:06:00Z</EstimatedTime></ServiceDeparture><Order>18</Order></CallAtStop></PreviousCall><PreviousCall><CallAtStop><siri:StopPointRef>ch:1:sloid:78883::300502</siri:StopPointRef><StopPointName><Text xml:lang="de">Locarno, Piazza Castello</Text></StopPointName><ServiceArrival><TimetabledTime>2026-09-07T08:03:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:07:00Z</EstimatedTime></ServiceArrival><ServiceDeparture><TimetabledTime>2026-09-07T08:03:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:07:00Z</EstimatedTime></ServiceDeparture><Order>19</Order></CallAtStop></PreviousCall><PreviousCall><CallAtStop><siri:StopPointRef>ch:1:sloid:80992::303302</siri:StopPointRef><StopPointName><Text xml:lang="de">Locarno, Atelier Remo Rossi</Text></StopPointName><ServiceArrival><TimetabledTime>2026-09-07T08:04:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:08:00Z</EstimatedTime></ServiceArrival><ServiceDeparture><TimetabledTime>2026-09-07T08:04:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:08:00Z</EstimatedTime></ServiceDeparture><Order>20</Order></CallAtStop></PreviousCall><PreviousCall><CallAtStop><siri:StopPointRef>ch:1:sloid:80994::336002</siri:StopPointRef><StopPointName><Text xml:lang="de">Locarno, Palexpo</Text></StopPointName><ServiceArrival><TimetabledTime>2026-09-07T08:04:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:08:00Z</EstimatedTime></ServiceArrival><ServiceDeparture><TimetabledTime>2026-09-07T08:04:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:08:00Z</EstimatedTime></ServiceDeparture><Order>21</Order></CallAtStop></PreviousCall><PreviousCall><CallAtStop><siri:StopPointRef>ch:1:sloid:7217::343602</siri:StopPointRef><StopPointName><Text xml:lang="de">Ascona, Fiume Maggia</Text></StopPointName><ServiceArrival><TimetabledTime>2026-09-07T08:06:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:10:00Z</EstimatedTime></ServiceArrival><ServiceDeparture><TimetabledTime>2026-09-07T08:06:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:10:00Z</EstimatedTime></ServiceDeparture><Order>22</Order></CallAtStop></PreviousCall><PreviousCall><CallAtStop><siri:StopPointRef>ch:1:sloid:91530::341502</siri:StopPointRef><StopPointName><Text xml:lang="de">Ascona, Via Pascolo</Text></StopPointName><ServiceArrival><TimetabledTime>2026-09-07T08:07:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:11:00Z</EstimatedTime></ServiceArrival><ServiceDeparture><TimetabledTime>2026-09-07T08:07:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:11:00Z</EstimatedTime></ServiceDeparture><Order>23</Order></CallAtStop></PreviousCall><PreviousCall><CallAtStop><siri:StopPointRef>ch:1:sloid:91521::308302</siri:StopPointRef><StopPointName><Text xml:lang="de">Ascona, Palestre</Text></StopPointName><ServiceArrival><TimetabledTime>2026-09-07T08:08:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:12:00Z</EstimatedTime></ServiceArrival><ServiceDeparture><TimetabledTime>2026-09-07T08:08:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:12:00Z</EstimatedTime></ServiceDeparture><Order>24</Order></CallAtStop></PreviousCall><PreviousCall><CallAtStop><siri:StopPointRef>ch:1:sloid:91529::341402</siri:StopPointRef><StopPointName><Text xml:lang="de">Ascona, Via Pancaldi Mola</Text></StopPointName><ServiceArrival><TimetabledTime>2026-09-07T08:08:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:12:00Z</EstimatedTime></ServiceArrival><ServiceDeparture><TimetabledTime>2026-09-07T08:08:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:12:00Z</EstimatedTime></ServiceDeparture><Order>25</Order></CallAtStop></PreviousCall><ThisCall><CallAtStop><siri:StopPointRef>ch:1:sloid:91522::308202</siri:StopPointRef><StopPointName><Text xml:lang="de">Ascona, Scuole</Text></StopPointName><ServiceDeparture><TimetabledTime>2026-09-07T08:09:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:13:00Z</EstimatedTime></ServiceDeparture><Order>26</Order></CallAtStop></ThisCall><OnwardCall><CallAtStop><siri:StopPointRef>ch:1:sloid:5850::301602</siri:StopPointRef><StopPointName><Text xml:lang="de">Ascona, Centro</Text></StopPointName><ServiceArrival><TimetabledTime>2026-09-07T08:11:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:15:00Z</EstimatedTime></ServiceArrival><ServiceDeparture><TimetabledTime>2026-09-07T08:11:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:15:00Z</EstimatedTime></ServiceDeparture><Order>27</Order></CallAtStop></OnwardCall><OnwardCall><CallAtStop><siri:StopPointRef>ch:1:sloid:91527::303601</siri:StopPointRef><StopPointName><Text xml:lang="de">Ascona, Parco dei Poeti</Text></StopPointName><ServiceArrival><TimetabledTime>2026-09-07T08:11:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:15:00Z</EstimatedTime></ServiceArrival><ServiceDeparture><TimetabledTime>2026-09-07T08:11:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:15:00Z</EstimatedTime></ServiceDeparture><Order>28</Order></CallAtStop></OnwardCall><OnwardCall><CallAtStop><siri:StopPointRef>ch:1:sloid:91528::303802</siri:StopPointRef><StopPointName><Text xml:lang="de">Ascona, Via Medere</Text></StopPointName><PlannedQuay><Text xml:lang="de">C</Text></PlannedQuay><ServiceArrival><TimetabledTime>2026-09-07T08:12:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:16:00Z</EstimatedTime></ServiceArrival><ServiceDeparture><TimetabledTime>2026-09-07T08:12:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:16:00Z</EstimatedTime></ServiceDeparture><Order>29</Order></CallAtStop></OnwardCall><OnwardCall><CallAtStop><siri:StopPointRef>ch:1:sloid:91518::308502</siri:StopPointRef><StopPointName><Text xml:lang="de">Ascona, Manor Delta</Text></StopPointName><ServiceArrival><TimetabledTime>2026-09-07T08:14:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:18:00Z</EstimatedTime></ServiceArrival><ServiceDeparture><TimetabledTime>2026-09-07T08:14:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:18:00Z</EstimatedTime></ServiceDeparture><Order>30</Order></CallAtStop></OnwardCall><OnwardCall><CallAtStop><siri:StopPointRef>ch:1:sloid:78924::343002</siri:StopPointRef><StopPointName><Text xml:lang="de">Losone, Ponte Maggia</Text></StopPointName><ServiceArrival><TimetabledTime>2026-09-07T08:15:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:19:00Z</EstimatedTime></ServiceArrival><ServiceDeparture><TimetabledTime>2026-09-07T08:15:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:19:00Z</EstimatedTime></ServiceDeparture><Order>31</Order></CallAtStop></OnwardCall><OnwardCall><CallAtStop><siri:StopPointRef>ch:1:sloid:76451::341802</siri:StopPointRef><StopPointName><Text xml:lang="de">Losone, Mercato Cattori</Text></StopPointName><ServiceArrival><TimetabledTime>2026-09-07T08:16:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:20:00Z</EstimatedTime></ServiceArrival><ServiceDeparture><TimetabledTime>2026-09-07T08:16:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:20:00Z</EstimatedTime></ServiceDeparture><Order>32</Order></CallAtStop></OnwardCall><OnwardCall><CallAtStop><siri:StopPointRef>ch:1:sloid:91549::301202</siri:StopPointRef><StopPointName><Text xml:lang="de">Losone, Agricola</Text></StopPointName><ServiceArrival><TimetabledTime>2026-09-07T08:17:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:21:00Z</EstimatedTime></ServiceArrival><ServiceDeparture><TimetabledTime>2026-09-07T08:17:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:21:00Z</EstimatedTime></ServiceDeparture><Order>33</Order></CallAtStop></OnwardCall><OnwardCall><CallAtStop><siri:StopPointRef>ch:1:sloid:91554::302904</siri:StopPointRef><StopPointName><Text xml:lang="de">Losone, Via Cesura</Text></StopPointName><ServiceArrival><TimetabledTime>2026-09-07T08:18:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:22:00Z</EstimatedTime></ServiceArrival><ServiceDeparture><TimetabledTime>2026-09-07T08:18:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:22:00Z</EstimatedTime></ServiceDeparture><Order>34</Order></CallAtStop></OnwardCall><OnwardCall><CallAtStop><siri:StopPointRef>ch:1:sloid:8245::344301</siri:StopPointRef><StopPointName><Text xml:lang="de">Losone, Sottochiesa</Text></StopPointName><ServiceArrival><TimetabledTime>2026-09-07T08:21:00Z</TimetabledTime><EstimatedTime>2026-09-07T08:25:00Z</EstimatedTime></ServiceArrival><Order>35</Order></CallAtStop></OnwardCall><Service><OperatingDayRef>2026-09-07</OperatingDayRef><JourneyRef>ch:1:sjyid:100616:793eaf40-ff15-4fde-b476-c10310329938</JourneyRef><PublicCode>1</PublicCode><LineRef>ojp:92001:M</LineRef><DirectionRef>R</DirectionRef><PublishedServiceName><Text xml:lang="de">1</Text></PublishedServiceName><TrainNumber>1054</TrainNumber><OriginStopPointRef>ch:1:sloid:6520::311701</OriginStopPointRef><OriginText><Text xml:lang="de">Gordola, Centro Professionale</Text></OriginText><OperatorRef>ojp:817</OperatorRef><DestinationStopPointRef>ch:1:sloid:8245::344301</DestinationStopPointRef><DestinationText><Text xml:lang="de">Losone, Sottochiesa</Text></DestinationText><PtMode>bus</PtMode></Service><OperatingDays><From>2026-08-23</From><To>2027-08-21</To><Pattern>0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111</Pattern></OperatingDays></StopEvent></StopEventResult>
"""#.utf8)
}
