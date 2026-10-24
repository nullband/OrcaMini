//
//  ContentView.swift
//  OrcaMini - the container app. The product is the AUv3 plugin inside it.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 14) {
            Text("ORCA·MINI").font(.system(size: 26, weight: .heavy, design: .monospaced)).foregroundColor(Color(red: 0.45, green: 0.87, blue: 0.76))
            Text("AUv3 MIDI plugin").font(.system(size: 14, design: .monospaced)).foregroundColor(.gray)
            Text("Open AUM, Drambo or any AUv3 host, add a MIDI plugin and pick OrcaMini. The host controls tempo and transport; route OrcaMini's MIDI out to your instruments.")
                .font(.system(size: 13)).foregroundColor(.white).multilineTextAlignment(.center).padding(.horizontal, 30)
            Text("Orca by Hundred Rabbits (MIT). This is an independent mobile port, not an official release.")
                .font(.system(size: 11)).foregroundColor(.gray).multilineTextAlignment(.center).padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
