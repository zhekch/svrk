// Recorded stop-based API responses for the reported RE1 on 2026-09-05.
// No authentication or passenger data is included.
enum ServiceConnectionFixtures {
    static let re1Incoming = #"""
{
  "trainMetaInformation": {
    "trainNumber": 4268,
    "toCode": "33",
    "runs": "J"
  },
  "formationsAtScheduledStops": [
    {
      "formationShort": {
        "formationShortString": "@A,F,F,[(2#VH;KW;NF,2#BHP;NF@B,1#KW;NF,12#VH;KW;NF,2#KW;NF,2)#VH;KW;NF],F,F@C,F,F,F,F@D,F,F,F,F,F",
        "vehicleGoals": [
          {
            "destinationStopPoint": {
              "name": "Bern",
              "uic": 8507000
            },
            "fromVehicleAtPosition": 1,
            "toVehicleAtPosition": 6
          }
        ]
      },
      "scheduledStop": {
        "stopModifications": 0,
        "stopPoint": {
          "name": "Brig",
          "uic": 8501609
        },
        "stopTime": {
          "arrivalTime": null,
          "departureTime": "2026-09-05T11:36:00+02:00"
        },
        "stopType": "H",
        "track": "8"
      }
    },
    {
      "formationShort": {
        "formationShortString": "[(2#VH;KW;NF,2#BHP;NF,1#KW;NF,12#VH;KW;NF,2#KW;NF,2)#VH;KW;NF]",
        "vehicleGoals": [
          {
            "destinationStopPoint": {
              "name": "Bern",
              "uic": 8507000
            },
            "fromVehicleAtPosition": 1,
            "toVehicleAtPosition": 6
          }
        ]
      },
      "scheduledStop": {
        "stopModifications": 0,
        "stopPoint": {
          "name": "Lalden",
          "uic": 8507470
        },
        "stopTime": {
          "arrivalTime": "2026-09-05T11:40:00+02:00",
          "departureTime": "2026-09-05T11:40:00+02:00"
        },
        "stopType": "B",
        "track": "2"
      }
    },
    {
      "formationShort": {
        "formationShortString": "[(2#VH;KW;NF,2#BHP;NF,1#KW;NF,12#VH;KW;NF,2#KW;NF,2)#VH;KW;NF]",
        "vehicleGoals": [
          {
            "destinationStopPoint": {
              "name": "Bern",
              "uic": 8507000
            },
            "fromVehicleAtPosition": 1,
            "toVehicleAtPosition": 6
          }
        ]
      },
      "scheduledStop": {
        "stopModifications": 0,
        "stopPoint": {
          "name": "Eggerberg",
          "uic": 8507471
        },
        "stopTime": {
          "arrivalTime": "2026-09-05T11:43:00+02:00",
          "departureTime": "2026-09-05T11:43:00+02:00"
        },
        "stopType": "B",
        "track": "1"
      }
    },
    {
      "formationShort": {
        "formationShortString": "[(2#VH;KW;NF,2#BHP;NF,1#KW;NF,12#VH;KW;NF,2#KW;NF,2)#VH;KW;NF]",
        "vehicleGoals": [
          {
            "destinationStopPoint": {
              "name": "Bern",
              "uic": 8507000
            },
            "fromVehicleAtPosition": 1,
            "toVehicleAtPosition": 6
          }
        ]
      },
      "scheduledStop": {
        "stopModifications": 0,
        "stopPoint": {
          "name": "Ausserberg",
          "uic": 8507472
        },
        "stopTime": {
          "arrivalTime": "2026-09-05T11:48:00+02:00",
          "departureTime": "2026-09-05T11:48:00+02:00"
        },
        "stopType": "H",
        "track": "3"
      }
    },
    {
      "formationShort": {
        "formationShortString": "[(2#VH;KW;NF,2#BHP;NF,1#KW;NF,12#VH;KW;NF,2#KW;NF,2)#VH;KW;NF]",
        "vehicleGoals": [
          {
            "destinationStopPoint": {
              "name": "Bern",
              "uic": 8507000
            },
            "fromVehicleAtPosition": 1,
            "toVehicleAtPosition": 6
          }
        ]
      },
      "scheduledStop": {
        "stopModifications": 0,
        "stopPoint": {
          "name": "Hohtenn",
          "uic": 8507473
        },
        "stopTime": {
          "arrivalTime": "2026-09-05T11:54:00+02:00",
          "departureTime": "2026-09-05T11:54:00+02:00"
        },
        "stopType": "B",
        "track": "2"
      }
    },
    {
      "formationShort": {
        "formationShortString": "@A,F,F@B,[(2#VH;KW;NF,2#BHP;NF,1#KW;NF@C,12#VH;KW;NF,2#KW;NF,2)#VH;KW;NF],F,F@D,F,F,F,F",
        "vehicleGoals": [
          {
            "destinationStopPoint": {
              "name": "Bern",
              "uic": 8507000
            },
            "fromVehicleAtPosition": 1,
            "toVehicleAtPosition": 6
          }
        ]
      },
      "scheduledStop": {
        "stopModifications": 0,
        "stopPoint": {
          "name": "Goppenstein",
          "uic": 8507474
        },
        "stopTime": {
          "arrivalTime": "2026-09-05T12:01:00+02:00",
          "departureTime": "2026-09-05T12:02:00+02:00"
        },
        "stopType": "H",
        "track": "1"
      }
    },
    {
      "formationShort": {
        "formationShortString": "@A,F,F@B,F,F@C,[(2#VH;KW;NF,2#BHP;NF,1#KW;NF@D,12#VH;KW;NF,2#KW;NF,2)#VH;KW;NF]",
        "vehicleGoals": [
          {
            "destinationStopPoint": {
              "name": "Bern",
              "uic": 8507000
            },
            "fromVehicleAtPosition": 1,
            "toVehicleAtPosition": 6
          }
        ]
      },
      "scheduledStop": {
        "stopModifications": 0,
        "stopPoint": {
          "name": "Kandersteg",
          "uic": 8507475
        },
        "stopTime": {
          "arrivalTime": "2026-09-05T12:13:00+02:00",
          "departureTime": "2026-09-05T12:14:00+02:00"
        },
        "stopType": "H",
        "track": "2"
      }
    },
    {
      "formationShort": {
        "formationShortString": "@A,F,F,F@B,F@C,F,[(2#VH;KW;NF,2#BHP;NF,1#KW;NF@D,12#VH;KW;NF,2#KW;NF,2)#VH;KW;NF]@E,F,F@F,F,F,F@G,F@H,F,F",
        "vehicleGoals": [
          {
            "destinationStopPoint": {
              "name": "Bern",
              "uic": 8507000
            },
            "fromVehicleAtPosition": 1,
            "toVehicleAtPosition": 6
          }
        ]
      },
      "scheduledStop": {
        "stopModifications": 0,
        "stopPoint": {
          "name": "Frutigen",
          "uic": 8507478
        },
        "stopTime": {
          "arrivalTime": "2026-09-05T12:29:00+02:00",
          "departureTime": "2026-09-05T12:30:00+02:00"
        },
        "stopType": "H",
        "track": "1"
      }
    },
    {
      "formationShort": {
        "formationShortString": "@A,F,F@B,[(2#VH;KW;NF,2#BHP;NF,1#KW;NF@C,12#VH;KW;NF,2#KW;NF,2)#VH;KW;NF]@D,F,F",
        "vehicleGoals": [
          {
            "destinationStopPoint": {
              "name": "Bern",
              "uic": 8507000
            },
            "fromVehicleAtPosition": 1,
            "toVehicleAtPosition": 6
          }
        ]
      },
      "scheduledStop": {
        "stopModifications": 0,
        "stopPoint": {
          "name": "Reichenbach im Kandertal",
          "uic": 8507480
        },
        "stopTime": {
          "arrivalTime": "2026-09-05T12:34:00+02:00",
          "departureTime": "2026-09-05T12:34:00+02:00"
        },
        "stopType": "H",
        "track": "2"
      }
    },
    {
      "formationShort": {
        "formationShortString": "@A,[(2#VH;KW;NF,2#BHP;NF,1#KW;NF,12#VH;KW;NF@B,2#KW;NF,2)#VH;KW;NF],F@C,F,F@D,F,F",
        "vehicleGoals": [
          {
            "destinationStopPoint": {
              "name": "Bern",
              "uic": 8507000
            },
            "fromVehicleAtPosition": 1,
            "toVehicleAtPosition": 6
          }
        ]
      },
      "scheduledStop": {
        "stopModifications": 0,
        "stopPoint": {
          "name": "Mülenen",
          "uic": 8507481
        },
        "stopTime": {
          "arrivalTime": "2026-09-05T12:35:00+02:00",
          "departureTime": "2026-09-05T12:35:00+02:00"
        },
        "stopType": "B",
        "track": "2"
      }
    },
    {
      "formationShort": {
        "formationShortString": "@A,F,F,F,F,F,F@B,F,F,F@C,[(2#VH;KW;NF,2#BHP;NF,1#KW;NF,12#VH;KW;NF,2#KW;NF,2)#VH;KW;NF]@D,F,F,F@E,F,F",
        "vehicleGoals": []
      },
      "scheduledStop": {
        "stopModifications": 0,
        "stopPoint": {
          "name": "Spiez",
          "uic": 8507483
        },
        "stopTime": {
          "arrivalTime": "2026-09-05T12:44:00+02:00",
          "departureTime": null
        },
        "stopType": "H",
        "track": "5"
      }
    }
  ]
}
"""#
    static let re1Outgoing = #"""
{
  "trainMetaInformation": {
    "trainNumber": 4168,
    "toCode": "33",
    "runs": "J"
  },
  "formationsAtScheduledStops": [
    {
      "formationShort": {
        "formationShortString": "@A,F,F,F,F,F,F@B,[(2#VH;KW;NF,2#BHP;NF,1#KW;NF,12#VH;KW;NF,2#KW;NF@C,2)#VH;KW;NF,(2#VH;KW;NF,2#BHP;NF,1#KW;NF,12#VH;KW;NF@D,2#KW;NF,2)#VH;KW;NF],F,F@E,F,F",
        "vehicleGoals": [
          {
            "destinationStopPoint": {
              "name": "Bern",
              "uic": 8507000
            },
            "fromVehicleAtPosition": 1,
            "toVehicleAtPosition": 12
          }
        ]
      },
      "scheduledStop": {
        "stopModifications": 0,
        "stopPoint": {
          "name": "Spiez",
          "uic": 8507483
        },
        "stopTime": {
          "arrivalTime": null,
          "departureTime": "2026-09-05T12:50:00+02:00"
        },
        "stopType": "H",
        "track": "5"
      }
    },
    {
      "formationShort": {
        "formationShortString": "@A,F,F,[(2#VH;KW;NF,2#BHP;NF,1#KW;NF@B,12#VH;KW;NF,2#KW;NF,2)#VH;KW;NF@C,(2#VH;KW;NF,2#BHP;NF,1#KW;NF@D,12#VH;KW;NF,2#KW;NF,2)#VH;KW;NF]@E,F,F@F,F,F,F@G,F,F",
        "vehicleGoals": [
          {
            "destinationStopPoint": {
              "name": "Bern",
              "uic": 8507000
            },
            "fromVehicleAtPosition": 1,
            "toVehicleAtPosition": 12
          }
        ]
      },
      "scheduledStop": {
        "stopModifications": 0,
        "stopPoint": {
          "name": "Thun",
          "uic": 8507100
        },
        "stopTime": {
          "arrivalTime": "2026-09-05T12:58:00+02:00",
          "departureTime": "2026-09-05T12:59:00+02:00"
        },
        "stopType": "H",
        "track": "2"
      }
    },
    {
      "formationShort": {
        "formationShortString": "@B,F,[(2#VH;KW;NF,2#BHP;NF,1#KW;NF,12#VH;KW;NF,2#KW;NF@C,2)#VH;KW;NF,(2#VH;KW;NF,2#BHP;NF,1#KW;NF@D,12#VH;KW;NF,2#KW;NF,2)#VH;KW;NF],F,F,F,F",
        "vehicleGoals": [
          {
            "destinationStopPoint": {
              "name": "Bern",
              "uic": 8507000
            },
            "fromVehicleAtPosition": 1,
            "toVehicleAtPosition": 12
          }
        ]
      },
      "scheduledStop": {
        "stopModifications": 0,
        "stopPoint": {
          "name": "Münsingen",
          "uic": 8507006
        },
        "stopTime": {
          "arrivalTime": "2026-09-05T13:08:00+02:00",
          "departureTime": "2026-09-05T13:08:00+02:00"
        },
        "stopType": "H",
        "track": "2"
      }
    },
    {
      "formationShort": {
        "formationShortString": "@H,[(2#VH;KW;NF,2#BHP;NF@G,1#KW;NF,12#VH;KW;NF,2#KW;NF,2)#VH;KW;NF@F,(2#VH;KW;NF,2#BHP;NF,1#KW;NF@E,12#VH;KW;NF,2#KW;NF,2)#VH;KW;NF]@D,F,F@C,F,F@B,F,F@A,F,F,F",
        "vehicleGoals": []
      },
      "scheduledStop": {
        "stopModifications": 0,
        "stopPoint": {
          "name": "Bern",
          "uic": 8507000
        },
        "stopTime": {
          "arrivalTime": "2026-09-05T13:22:00+02:00",
          "departureTime": null
        },
        "stopType": "H",
        "track": "2"
      }
    }
  ]
}
"""#
}
