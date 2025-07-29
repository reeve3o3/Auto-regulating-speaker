#!/usr/bin/env python3
import os
import serial
import time
import math
import json
from typing import Optional, Dict, List
from dataclasses import dataclass
from flask import Flask, request, jsonify
from flask_cors import CORS
import threading
import RPi.GPIO as GPIO
import socket

# ==================== 伺服馬達控制設定 ====================
SERVO_PIN = 17
GPIO.setmode(GPIO.BCM)
GPIO.setup(SERVO_PIN, GPIO.OUT)

servo_pwm = GPIO.PWM(SERVO_PIN, 50)
def angle_to_duty(angle: float) -> float:
    return 2.5 + (angle / 180.0) * 10.0

center_angle = 90
servo_pwm.start(angle_to_duty(center_angle))
print(f"伺服馬達初始化至中間位置：{center_angle}°")
time.sleep(0.5)
servo_pwm.ChangeDutyCycle(0)

# ==================== 音量控制函式 ====================
def calculate_volume(distance: float) -> int:
    if distance <= 0.5:
        return 60
    elif distance <= 1.0:
        return int(60 + (12 / 0.5) * (distance - 0.5))
    elif distance <= 2.0:
        return int(72 + (13 / 1.0) * (distance - 1.0))
    elif distance <= 3.0:
        return int(85 + (15 / 1.0) * (distance - 2.0))
    else:
        return 100

def set_volume(volume: int):
    os.system(f"amixer set Master {volume}%")

# ==================== 自定義位置管理 ====================
@dataclass
class CustomPosition:
    name: str
    angle: float
    distance: float
    volume: int

class PositionManager:
    def __init__(self, positions_file: str = 'positions.json'):
        self.positions_file = positions_file
        self.positions: List[CustomPosition] = []
        self.angle_tolerance = 5
        self.distance_tolerance = 0.1
        self.load_positions()

    def load_positions(self):
        try:
            with open(self.positions_file, 'r') as f:
                data = json.load(f)
                self.positions = [
                    CustomPosition(
                        p['name'],
                        p['angle'],
                        p['distance'],
                        p['volume']
                    ) for p in data
                ]
            print("已載入自定義位置")
        except FileNotFoundError:
            print("找不到自定義位置檔案，使用預設設定")
            self.positions = []
        except json.JSONDecodeError:
            print("自定義位置檔案格式錯誤，使用預設設定")
            self.positions = []

    def save_positions(self):
        data = [
            {
                'name': p.name,
                'angle': p.angle,
                'distance': p.distance,
                'volume': p.volume
            } for p in self.positions
        ]
        with open(self.positions_file, 'w') as f:
            json.dump(data, f, indent=4)
        print("已儲存自定義位置")

    def add_position(self, name: str, angle: float, distance: float, volume: int):
        position = CustomPosition(name, angle, distance, volume)
        self.positions.append(position)
        self.save_positions()
        return position

    def remove_position(self, name: str):
        self.positions = [p for p in self.positions if p.name != name]
        self.save_positions()

    def check_position_trigger(self, current_angle: float, current_distance: float) -> Optional[CustomPosition]:
        for position in self.positions:
            if (abs(position.angle - current_angle) <= self.angle_tolerance and 
                abs(position.distance - current_distance) <= self.distance_tolerance):
                return position
        return None

    def get_all_positions(self):
        return self.positions

# ==================== 伺服馬達控制類 ====================
class ServoController:
    def __init__(self):
        self.current_angle = center_angle
        self.angle_tolerance = 5
        self.last_move_time = time.time()
        self.stabilize_delay = 0.2
        self.auto_tracking = True  # 預設為自動跟踪

    def set_angle(self, target_angle: float):
        # 如果不是自動跟踪模式，則不自動更新角度
        if not self.auto_tracking:
            return

        if target_angle < 30:
            target_angle = 30
        elif target_angle > 150:
            target_angle = 150

        angle_diff = abs(target_angle - self.current_angle)
        if angle_diff > self.angle_tolerance:
            duty = angle_to_duty(target_angle)
            servo_pwm.ChangeDutyCycle(duty)
            print(f"設定伺服馬達角度：{target_angle}° (Duty: {duty:.2f})")
            self.current_angle = target_angle
            self.last_move_time = time.time()
            time.sleep(self.stabilize_delay)
            servo_pwm.ChangeDutyCycle(0)
            
    def set_manual_angle(self, target_angle: float):
        """手動設定伺服馬達角度，不論自動/手動模式"""
        if target_angle < 30:
            target_angle = 30
        elif target_angle > 150:
            target_angle = 150

        duty = angle_to_duty(target_angle)
        servo_pwm.ChangeDutyCycle(duty)
        print(f"手動設定伺服馬達角度：{target_angle}° (Duty: {duty:.2f})")
        self.current_angle = target_angle
        self.last_move_time = time.time()
        time.sleep(0.7)
        servo_pwm.ChangeDutyCycle(0)
    
    def set_tracking_mode(self, auto_tracking: bool):
        """設定是否自動跟踪目標"""
        self.auto_tracking = auto_tracking
        print(f"伺服馬達跟踪模式: {'自動' if auto_tracking else '手動'}")
        return self.auto_tracking

# ==================== UWB 讀取器類 ====================
class UWBReader:
    def __init__(self, port: str = '/dev/ttyS0', baud_rate: int = 115200, positions_file: str = 'positions.json'):
        self.PI = math.pi
        self.last_data_time = time.time()
        self.timeout = 0.5
        self.servo = ServoController()
        self.mode = "auto"  # 'auto', 'custom', 或 'custom2'
        self.position_manager = PositionManager(positions_file=positions_file)
        
        # 初始化預設數據
        self.current_data = {
            'address': "Not connected",
            'angle': 90.0,
            'distance': 0.0,
            'volume': 60
        }
        
        # 自定義模式下，初始音量預設為 60
        self.last_custom_volume = 60
        # 手動控制音量，用於 custom2 模式
        self.manual_volume = 60

        try:
            self.serial = serial.Serial(
                port=port,
                baudrate=baud_rate,
                bytesize=serial.EIGHTBITS,
                parity=serial.PARITY_NONE,
                stopbits=serial.STOPBITS_ONE,
                timeout=0.1
            )
            print(f"已開啟串口 {port}，波特率 {baud_rate}")
            self.reset_connection()
        except Exception as e:
            print(f"無法開啟串口 {port}: {e}")
            raise

    def set_servo_tracking(self, auto_tracking: bool):
        result = self.servo.set_tracking_mode(auto_tracking)
        return result

    def set_servo_angle(self, angle: float):
        self.servo.set_manual_angle(angle)
        self.current_data['servo_angle'] = angle
        return angle

    def set_mode(self, mode: str):
        previous_mode = self.mode
        self.mode = mode
        print(f"Mode changed to: {mode}")
        
        # 當切換到手動模式時，確保使用正確的音量
        if mode == "custom2":
            set_volume(self.manual_volume)
            self.current_data['volume'] = self.manual_volume
        # 當從手動模式切換到其他模式時，重置預設音量
        elif previous_mode == "custom2":
            if mode == "auto":
                # 自動模式使用距離計算音量
                distance = self.current_data.get('distance', 0.0)
                volume = calculate_volume(distance)
                set_volume(volume)
                self.current_data['volume'] = volume
            elif mode == "custom":
                # 自定義模式使用上次自定義音量
                set_volume(self.last_custom_volume)
                self.current_data['volume'] = self.last_custom_volume
            
    def set_manual_volume(self, volume: int):
        self.manual_volume = volume
        
        # 更新當前數據，不論是否有 UWB 通訊
        if self.current_data:
            self.current_data['volume'] = volume
        
        # 如果在手動模式下，立即設置音量
        if self.mode == "custom2":
            set_volume(volume)
            
        print(f"Manual volume set to: {volume}%")
        return volume

    def reset_connection(self):
        self.serial.reset_input_buffer()
        self.serial.reset_output_buffer()
        print("已重置串口連接並清空緩衝區")

    def check_data_timeout(self) -> bool:
        current_time = time.time()
        if current_time - self.last_data_time > self.timeout:
            print("數據超時，未收到新數據，維持目前狀態")
            return True
        return False

    def process_valid_data(self, data: bytes) -> Optional[dict]:
        self.last_data_time = time.time()
        address = (data[3] << 8) | data[4]
        raw_angle = data[5]
        raw_distance = (data[9] |
                        (data[10] << 8) |
                        (data[11] << 16) |
                        (data[12] << 24))
        
        real_distance = (0.3 / (2 * self.PI)) * (raw_distance / (2 * self.PI))
        
        if data[6] == 0xFF and data[7] == 0xFF and data[8] == 0xFF:
            real_angle = 255 - raw_angle
        elif data[6] == 0x00 and data[7] == 0x00 and data[8] == 0x00:
            real_angle = 0 - raw_angle
        else:
            return None

        servo_angle = 90 - real_angle
        self.servo.set_angle(servo_angle)

        # 根據模式決定音量控制方式，並記錄目前的音量值
        current_volume = 0
        
        if self.mode == "auto":
            # 自動模式：根據距離調整音量
            target_volume = calculate_volume(real_distance)
            set_volume(target_volume)
            current_volume = target_volume
        elif self.mode == "custom":
            # 自定義模式：當接近特定位置時使用預設音量
            triggered_position = self.position_manager.check_position_trigger(real_angle, real_distance)
            if triggered_position:
                set_volume(triggered_position.volume)
                self.last_custom_volume = triggered_position.volume
                current_volume = triggered_position.volume
            else:
                set_volume(self.last_custom_volume)
                current_volume = self.last_custom_volume
        elif self.mode == "custom2":
            # 手動模式：使用手動設置的音量
            current_volume = self.manual_volume
            # 注意：手動模式不需要在這裡設置音量，因為已經通過 set_manual_volume 設置了
        
        # 更新當前數據，但在手動模式下保持手動設置的音量
        result = {
            'address': hex(address),
            'angle': real_angle,
            'distance': real_distance,
            'volume': self.manual_volume if self.mode == "custom2" else current_volume
        }
        
        self.current_data = result
        print(f"地址: 0x{address:04X} | 角度: {real_angle}° | 距離: {real_distance:.2f} m | 音量: {result['volume']}%")
        return result

    def read_data(self):
        try:
            while True:
                self.check_data_timeout()
                if self.serial.in_waiting > 31:
                    self.reset_connection()
                if self.serial.in_waiting >= 31:
                    data = self.serial.read(31)
                    if data[0] == 0x2A and data[30] == 0x23:
                        self.process_valid_data(data)
                    else:
                        self.serial.read()
                time.sleep(0.01)
        except KeyboardInterrupt:
            print("\n程式已停止")
            self.serial.close()
            GPIO.cleanup()
        except Exception as e:
            print(f"發生錯誤: {e}")
            self.serial.close()
            GPIO.cleanup()

# ==================== Flask 伺服器設定 ====================
app = Flask(__name__)
CORS(app)
uwb_reader = None

@app.route('/servo/tracking', methods=['POST'])
def set_servo_tracking():
    auto_tracking = request.json.get('auto_tracking')
    if isinstance(auto_tracking, bool):
        result = uwb_reader.set_servo_tracking(auto_tracking)
        return jsonify({"status": "success", "auto_tracking": result})
    return jsonify({"status": "error", "message": "Invalid parameter"}), 400

@app.route('/servo/angle', methods=['POST'])
def set_servo_angle():
    angle = request.json.get('angle')
    if isinstance(angle, (int, float)) and 30 <= angle <= 150:
        result = uwb_reader.set_servo_angle(float(angle))
        return jsonify({"status": "success", "angle": result})
    return jsonify({"status": "error", "message": "Invalid angle"}), 400

@app.route('/mode', methods=['POST'])
def set_mode_route():
    mode = request.json.get('mode')
    if mode in ['auto', 'custom', 'custom2']:
        uwb_reader.set_mode(mode)
        return jsonify({"status": "success", "mode": mode})
    return jsonify({"status": "error", "message": "Invalid mode"}), 400

@app.route('/volume', methods=['POST'])
def set_volume_route():
    volume = request.json.get('volume')
    if isinstance(volume, int) and 0 <= volume <= 100:
        result = uwb_reader.set_manual_volume(volume)
        return jsonify({"status": "success", "volume": result})
    return jsonify({"status": "error", "message": "Invalid volume"}), 400

@app.route('/position', methods=['POST'])
def add_position():
    data = request.json
    position = uwb_reader.position_manager.add_position(
        data['name'],
        data['angle'],
        data['distance'],
        data['volume']
    )
    return jsonify({
        "status": "success",
        "position": {
            "name": position.name,
            "angle": position.angle,
            "distance": position.distance,
            "volume": position.volume
        }
    })

@app.route('/position/<name>', methods=['DELETE'])
def remove_position(name):
    uwb_reader.position_manager.remove_position(name)
    return jsonify({"status": "success"})

@app.route('/positions', methods=['GET'])
def get_positions():
    positions = uwb_reader.position_manager.get_all_positions()
    return jsonify([{
        "name": p.name,
        "angle": p.angle,
        "distance": p.distance,
        "volume": p.volume
    } for p in positions])

@app.route('/current-data', methods=['GET'])
def get_current_data():
    # 若在手動模式下，確保返回的數據包含最新的手動音量設置
    if uwb_reader.mode == "custom2":
        uwb_reader.current_data['volume'] = uwb_reader.manual_volume
        
    return jsonify(uwb_reader.current_data)

def get_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(('8.8.8.8', 80))
        ip = s.getsockname()[0]
    except Exception:
        ip = '127.0.0.1'
    finally:
        s.close()
    return ip

@app.route('/pi-ip', methods=['GET'])
def get_pi_ip():
    return jsonify({"ip": get_ip()})

# ==================== 主程式 ====================
if __name__ == "__main__":
    try:
        uwb_reader = UWBReader(port='/dev/ttyS0', baud_rate=115200, positions_file='positions.json')
        # 在另一個執行緒中運行 Flask 伺服器
        server_thread = threading.Thread(
            target=app.run, 
            kwargs={'host': '0.0.0.0', 'port': 5000}
        )
        server_thread.daemon = True
        server_thread.start()
        # 運行 UWB 讀取器
        uwb_reader.read_data()
    except Exception as e:
        print(f"程式發生錯誤: {e}")
        GPIO.cleanup()