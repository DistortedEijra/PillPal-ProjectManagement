
import 'package:flutter/material.dart';
import 'auth_service.dart';

enum AuthMode { Login, SignUp }

class AuthPage extends StatefulWidget {
  const AuthPage({super.key});

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final AuthService _authService = AuthService();
  AuthMode _authMode = AuthMode.Login;

  final TextEditingController nameController = TextEditingController();
  final TextEditingController ageController = TextEditingController();
  final TextEditingController emailController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  final TextEditingController confirmPasswordController = TextEditingController();

  final List<String> _genders = ['Male', 'Female', 'Other'];
  String? _selectedGender;

  bool _isLoading = false;

  void _toggleAuthMode() {
    setState(() {
      _authMode = _authMode == AuthMode.Login ? AuthMode.SignUp : AuthMode.Login;
    });
  }

  Future<void> _submit() async {
    if (_isLoading) return;

    setState(() {
      _isLoading = true;
    });

    String? result;
    try {
      if (_authMode == AuthMode.Login) {
        result = await _authService.signIn(
          email: emailController.text.trim(),
          password: passwordController.text.trim(),
        );
      } else {
        if (passwordController.text != confirmPasswordController.text) {
          result = "Passwords do not match.";
        } else if (nameController.text.isEmpty ||
            ageController.text.isEmpty ||
            _selectedGender == null ||
            emailController.text.isEmpty) {
          result = "Please fill all fields.";
        } else {
          result = await _authService.signUp(
            email: emailController.text.trim(),
            password: passwordController.text.trim(),
            name: nameController.text.trim(),
            age: ageController.text.trim(),
            gender: _selectedGender!,
          );
        }
      }
    } catch (e) {
      result = 'Something went wrong: $e';
    } finally {
      // Always stop the spinner, even if something unexpected failed.
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }

    if (result != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result)),
      );
    }
    // If successful, the auth wrapper will handle navigation
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Color(0xFF116FA9),
      body: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.asset('assets/icon.png', height: 120),
              const Text('PillPal', style: TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 20),
              Container(
                width: 340,
                padding: const EdgeInsets.all(24.0),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 10, offset: Offset(0, 4))],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_authMode == AuthMode.Login ? "Login" : "Create Account", style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 24),
                    if (_authMode == AuthMode.SignUp)
                      ...[
                        _buildTextField(label: "Given Name", controller: nameController),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(child: _buildTextField(label: "Age", controller: ageController, keyboardType: TextInputType.number)),
                            const SizedBox(width: 16),
                            Expanded(child: _buildGenderDropdown()),
                          ],
                        ),
                        const SizedBox(height: 16),
                      ],
                    _buildTextField(label: "Email Address", controller: emailController, keyboardType: TextInputType.emailAddress),
                    const SizedBox(height: 16),
                    _buildTextField(label: "Password", controller: passwordController, obscureText: true),
                    if (_authMode == AuthMode.SignUp)
                      ...[
                        const SizedBox(height: 16),
                        _buildTextField(label: "Re-type password", controller: confirmPasswordController, obscureText: true),
                      ],
                    const SizedBox(height: 24),
                    _isLoading
                        ? CircularProgressIndicator()
                        : SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Color(0xFF116FA9),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                padding: EdgeInsets.symmetric(vertical: 14),
                              ),
                              onPressed: _submit,
                              child: Text(_authMode == AuthMode.Login ? "Sign In" : "Sign Up", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                            ),
                          ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(_authMode == AuthMode.Login ? "Don't have an account? " : "Already have an account? ", style: TextStyle(color: Colors.white)),
                  GestureDetector(
                    onTap: _toggleAuthMode,
                    child: Text(_authMode == AuthMode.Login ? "Sign Up" : "Sign In", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, decoration: TextDecoration.underline)),
                  ),
                ],
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTextField({required String label, required TextEditingController controller, bool obscureText = false, TextInputType keyboardType = TextInputType.text}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.black87, fontSize: 14)),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          obscureText: obscureText,
          keyboardType: keyboardType,
          decoration: InputDecoration(
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            filled: true,
            fillColor: const Color(0xFFF0F0F0),
            contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          ),
          style: const TextStyle(color: Colors.black87),
        ),
      ],
    );
  }

  Widget _buildGenderDropdown() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text("Gender", style: TextStyle(color: Colors.black87, fontSize: 14)),
        const SizedBox(height: 4),
        DropdownButtonFormField<String>(
          initialValue: _selectedGender,
          isExpanded: true,
          decoration: InputDecoration(
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            filled: true,
            fillColor: const Color(0xFFF0F0F0),
            contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
          dropdownColor: const Color(0xFFF0F0F0),
          style: const TextStyle(color: Colors.black87),
          hint: const Text("Select", style: TextStyle(color: Colors.black54)),
          onChanged: (String? newValue) {
            setState(() {
              _selectedGender = newValue;
            });
          },
          items: _genders.map<DropdownMenuItem<String>>((String value) {
            return DropdownMenuItem<String>(value: value, child: Text(value));
          }).toList(),
        ),
      ],
    );
  }
}
