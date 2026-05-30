import SwiftUI

struct Preview3DControls: View {
    @Bindable var generator: TextureGenerator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // MARK: Actions
                Button(action: { generator.applyTexturesToBall() }) {
                    Label("Apply Textures", systemImage: "cube.transparent.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(generator.sourceImage == nil)

                Button(action: { generator.refocusCamera() }) {
                    Label("Refocus Camera", systemImage: "scope")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                HStack {
                    Label("Show Light Positions", systemImage: "light.beacon.max.fill")
                        .font(.subheadline)
                    Spacer()
                    Toggle("", isOn: $generator.showLightGizmos)
                        .labelsHidden()
                }

                Divider()

                // MARK: Environment (IBL)
                Group {
                    HStack {
                        Label("Environment", systemImage: "globe.europe.africa.fill")
                            .font(.headline)
                        Spacer()
                        Button("Reset") {
                            generator.iblPreset            = .neutralStudio
                            generator.iblRotation          = 0
                            generator.bounceLightIntensity = 1.0
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    Picker("", selection: $generator.iblPreset) {
                        ForEach(TextureGenerator.IBLPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    sliderRow(label: "Rotation",  value: $generator.iblRotation,          range: 0...360, format: "%.0f°")
                    sliderRow(label: "Intensity", value: $generator.bounceLightIntensity, range: 0...2,   format: "%.2f")
                }

                Divider()

                // MARK: Lighting Rig
                Group {
                    Label("Lighting Rig", systemImage: "lightbulb.2.fill")
                        .font(.headline)
                    Picker("", selection: $generator.lightingRig) {
                        ForEach(TextureGenerator.LightingRig.allCases) { rig in
                            Text(rig.rawValue).tag(rig)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Divider()

                // MARK: Key Light
                Group {
                    HStack {
                        Label(generator.lightingRig == .row ? "Row Lights" : "Key Light",
                              systemImage: generator.lightingRig == .row ? "light.strip.2" : "lightbulb.fill")
                            .font(.headline)
                        Spacer()
                        Button("Reset") {
                            generator.lightAzimuth     = 45
                            generator.lightElevation   = 35
                            generator.lightIntensity   = 1500
                            generator.lightTemperature = 6500
                            generator.lightColor       = .white
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    if generator.lightingRig != .row {
                        sliderRow(label: "Azimuth",   value: $generator.lightAzimuth,   range: 0...360, format: "%.0f°")
                        sliderRow(label: "Elevation", value: $generator.lightElevation, range: -90...90, format: "%.0f°")
                    }
                    sliderRow(label: "Intensity",    value: $generator.lightIntensity,   range: 100...4000,  format: "%.0f")
                    sliderRow(label: "Temperature",  value: $generator.lightTemperature, range: 2000...10000, format: "%.0fK")
                    HStack {
                        Text("Color:")
                        Spacer()
                        ColorPicker("", selection: $generator.lightColor, supportsOpacity: false)
                            .labelsHidden()
                    }
                }

                Divider()

                // MARK: Fill & Rim — hidden for Row rig
                if generator.lightingRig != .row {
                    Group {
                        HStack {
                            Label("Fill & Rim", systemImage: "rays")
                                .font(.headline)
                            Spacer()
                            Button("Reset") {
                                generator.fillLightIntensity = 500
                                generator.rimLightIntensity  = 200
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                        sliderRow(label: "Fill Intensity", value: $generator.fillLightIntensity, range: 0...2000, format: "%.0f")
                        sliderRow(label: "Rim Intensity",  value: $generator.rimLightIntensity,  range: 0...1000, format: "%.0f")
                    }

                    Divider()
                }

                // MARK: Camera Fill
                Group {
                    HStack {
                        Label("Camera Fill", systemImage: "camera.metering.center.weighted")
                            .font(.headline)
                        Spacer()
                        Toggle("", isOn: $generator.cameraFillEnabled)
                            .labelsHidden()
                    }
                    if generator.cameraFillEnabled {
                        sliderRow(label: "Intensity", value: $generator.cameraFillIntensity, range: 0...1500, format: "%.0f")
                        HStack {
                            Text("Color:")
                            Spacer()
                            ColorPicker("", selection: $generator.cameraFillColor, supportsOpacity: false)
                                .labelsHidden()
                        }
                    }
                }

                Divider()

                // MARK: Ring Light (beauty / donut light)
                Group {
                    HStack {
                        Label("Ring Light", systemImage: "circle.dashed")
                            .font(.headline)
                        Spacer()
                        Toggle("", isOn: $generator.ringLightEnabled)
                            .labelsHidden()
                    }
                    if generator.ringLightEnabled {
                        sliderRow(label: "Intensity", value: $generator.ringLightIntensity, range: 0...3000, format: "%.0f")
                        sliderRow(label: "Radius",    value: $generator.ringLightRadius,    range: 0.05...0.6, format: "%.2f")
                        HStack {
                            Text("Color:")
                            Spacer()
                            ColorPicker("", selection: $generator.ringLightColor, supportsOpacity: false)
                                .labelsHidden()
                        }
                    }
                }

                Divider()

                // MARK: Under Light
                Group {
                    HStack {
                        Label("Under Light", systemImage: "flashlight.on.fill")
                            .font(.headline)
                        Spacer()
                        Toggle("", isOn: $generator.underLightEnabled)
                            .labelsHidden()
                    }
                    if generator.underLightEnabled {
                        sliderRow(label: "Intensity", value: $generator.underLightIntensity, range: 0...3000, format: "%.0f")
                        sliderRow(label: "Spread",    value: $generator.underLightSpread,    range: 10...90,  format: "%.0f°")
                        HStack {
                            Text("Color:")
                            Spacer()
                            ColorPicker("", selection: $generator.underLightColor, supportsOpacity: false)
                                .labelsHidden()
                        }
                    }
                }

                Divider()

                // MARK: Ball Texture
                Group {
                    HStack {
                        Label("Ball Texture", systemImage: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left")
                            .font(.headline)
                        Spacer()
                        Button("Reset") {
                            generator.ballTextureScale    = 1.0
                            generator.ballTextureOffsetX  = 0
                            generator.ballTextureOffsetY  = 0
                            generator.ballTextureRotation = 0
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    sliderRow(label: "Scale", value: $generator.ballTextureScale,   range: 0.1...8.0, format: "%.2fx")
                    sliderRow(label: "Pan X", value: $generator.ballTextureOffsetX, range: -1...1,    format: "%.2f")
                    sliderRow(label: "Pan Y", value: $generator.ballTextureOffsetY, range: -1...1,    format: "%.2f")
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading) {
                            Text("Rotation:")
                            Text("\(Int(generator.ballTextureRotation))°")
                                .monospacedDigit()
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        RotationDial(angle: $generator.ballTextureRotation)
                            .frame(width: 56, height: 56)
                    }
                }

                Divider()

                // MARK: Studio Floor
                Group {
                    HStack {
                        Label("Studio Floor", systemImage: "square.3.layers.3d")
                            .font(.headline)
                        Spacer()
                        Button("Reset") {
                            generator.floorStyle = .reflective
                            generator.floorColor = Color(white: 0.38)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    Picker("", selection: $generator.floorStyle) {
                        ForEach(TextureGenerator.FloorStyle.allCases) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Text("Floor Color:")
                        Spacer()
                        ColorPicker("", selection: $generator.floorColor, supportsOpacity: false)
                            .labelsHidden()
                    }
                }

                Divider()

                // MARK: Camera Orbit
                Group {
                    HStack {
                        Label("Camera Orbit", systemImage: "camera.rotate")
                            .font(.headline)
                        Spacer()
                        Button("Reset") {
                            generator.cameraAzimuth   = 45
                            generator.cameraElevation = 20
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    sliderRow(label: "Azimuth",   value: $generator.cameraAzimuth,   range: -180...180, format: "%.0f°")
                    sliderRow(label: "Elevation", value: $generator.cameraElevation, range: -45...85,   format: "%.0f°")
                }
            }
            .padding(16)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.black.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 4)
    }

    @ViewBuilder
    private func sliderRow(label: String, value: Binding<Float>, range: ClosedRange<Float>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(label):")
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .monospacedDigit()
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Slider(value: value, in: range)
        }
    }
}
